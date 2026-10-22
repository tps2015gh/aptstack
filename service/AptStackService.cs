// ==========================================================================
// aptstack-svc.exe - Windows Service host สำหรับ aptstack
//
// compile (ทำโดย service.ps1):
//   csc.exe /nologo /target:exe /out:bin\aptstack-svc.exe ^
//           /r:System.ServiceProcess.dll service\AptStackService.cs
//
// ทำไม compile เอง: ไม่ต้องดาวน์โหลด NSSM/WinSW ตอนติดตั้ง
//                    และได้ .NET Framework exe ที่รันใต้ SCM ได้ตรงๆ
//
// หน้าที่:
//   OnStart -> spawn `powershell aptstack.ps1 service-run`
//   OnStop  -> แตะ runtime\stop.flag ให้ script ปิด stack แบบ clean แล้วรอ
//   watchdog-> ถ้าตัว script ตายเอง ให้ stop ตัวเอง เพื่อให้ SCM restart
// ==========================================================================

using System;
using System.Diagnostics;
using System.IO;
using System.ServiceProcess;
using System.Threading;

namespace AptStack
{
    public class AptStackService : ServiceBase
    {
        private Process _runner;
        private Thread _watchdog;
        private volatile bool _stopping;
        private string _root;
        private string _flag;

        public AptStackService()
        {
            ServiceName = "AptStack";
            CanStop = true;
            CanPauseAndContinue = false;
            CanShutdown = true;
            AutoLog = false;
        }

        private static string FindRoot(string startDir)
        {
            DirectoryInfo d = new DirectoryInfo(startDir);
            for (int i = 0; i < 5 && d != null; i++)
            {
                if (File.Exists(Path.Combine(d.FullName, "aptstack.ps1"))) return d.FullName;
                d = d.Parent;
            }
            return startDir;
        }

        protected override void OnStart(string[] args)
        {
            _stopping = false;
            _root = FindRoot(AppDomain.CurrentDomain.BaseDirectory);
            string runtime = Path.Combine(_root, "config");
            if (!Directory.Exists(runtime)) Directory.CreateDirectory(runtime);
            _flag = Path.Combine(runtime, "stop.flag");
            try { if (File.Exists(_flag)) File.Delete(_flag); } catch { }

            string script = Path.Combine(_root, "aptstack.ps1");
            if (!File.Exists(script))
            {
                ExitCode = 2;
                throw new FileNotFoundException("aptstack.ps1 not found", script);
            }

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\" service-run";
            psi.WorkingDirectory = _root;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = false;
            psi.RedirectStandardError = false;

            _runner = Process.Start(psi);

            _watchdog = new Thread(WatchLoop);
            _watchdog.IsBackground = true;
            _watchdog.Start();
        }

        private void WatchLoop()
        {
            while (!_stopping)
            {
                Thread.Sleep(5000);
                Process p = _runner;
                if (p == null) continue;
                try
                {
                    if (p.HasExited && !_stopping)
                    {
                        // ตัว service-run ตายเอง -> ให้ SCM restart ตาม sc failure
                        try { Stop(); } catch { }
                        return;
                    }
                }
                catch { }
            }
        }

        protected override void OnStop()
        {
            StopStack(25000);
        }

        protected override void OnShutdown()
        {
            StopStack(30000);
        }

        private void StopStack(int waitMs)
        {
            _stopping = true;
            try
            {
                if (!string.IsNullOrEmpty(_flag) && Directory.Exists(Path.GetDirectoryName(_flag)))
                    File.WriteAllText(_flag, DateTime.Now.ToString("o"));
            }
            catch { }

            Process p = _runner;
            if (p != null)
            {
                try
                {
                    if (!p.WaitForExit(waitMs))
                    {
                        KillTree(p.Id);
                        p.WaitForExit(5000);
                    }
                }
                catch { }
            }

            // กวาด port ที่เหลือ (php / mariadbd อาจค้าง)
            TryKillPort(ReadPort("httpPort", 8077));
            TryKillPort(ReadPort("dbPort", 3307));
            _runner = null;
        }

        private int ReadPort(string key, int fallback)
        {
            try
            {
                string cfg = Path.Combine(_root, "config", "stack.json");
                if (!File.Exists(cfg)) return fallback;
                string txt = File.ReadAllText(cfg);
                int i = txt.IndexOf("\"" + key + "\"", StringComparison.OrdinalIgnoreCase);
                if (i < 0) return fallback;
                int c = txt.IndexOf(':', i);
                int j = c + 1;
                while (j < txt.Length && (txt[j] == ' ' || txt[j] == '\t')) j++;
                string num = "";
                while (j < txt.Length && char.IsDigit(txt[j])) { num += txt[j]; j++; }
                int v;
                if (int.TryParse(num, out v)) return v;
            }
            catch { }
            return fallback;
        }

        private void TryKillPort(int port)
        {
            if (port <= 0) return;
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = "powershell.exe";
                psi.Arguments = "-NoProfile -Command \"$c=Get-NetTCPConnection -LocalPort " + port +
                                " -State Listen -ErrorAction SilentlyContinue; if($c){$c.OwningProcess|Sort-Object -Unique|ForEach-Object{Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue}}\"";
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                Process p = Process.Start(psi);
                p.WaitForExit(8000);
            }
            catch { }
        }

        private void KillTree(int pid)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = "taskkill.exe";
                psi.Arguments = "/PID " + pid + " /T /F";
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                Process p = Process.Start(psi);
                p.WaitForExit(8000);
            }
            catch { }
        }
    }

    public static class Program
    {
        public static void Main(string[] args)
        {
            ServiceBase.Run(new AptStackService());
        }
    }
}
