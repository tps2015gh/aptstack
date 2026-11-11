// db_manager.go — MariaDB/MySQL backup·restore·audit for aptstack + production server
//
// Checks (fail loudly, never silent):
//  1. mysql.exe / mysqldump.exe exist on disk (not just LookPath)
//  2. real login test — capture stderr, show server error text
//  3. connection encoding — SET NAMES + verify character_set results
//  4. port: aptstack config/stack.json dbPort (3307 local) else 3306 (server default)
//  5. retry credentials on connection failure until user gives up
//
// Build:  go build -o db_manager.exe .
// Run:    db_manager.exe   (from aptstack root or anywhere)
package main

import (
	"archive/zip"
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// ---------------------------------------------------------------- config

type stackConfig struct {
	App    string `json:"app"`
	MySQL  string `json:"mysql"`
	DBPort int    `json:"dbPort"`
	DBUser string `json:"dbUser"`
	DBPass string `json:"dbPass"`
	DBMode string `json:"dbMode"`
}

type appConfig struct {
	BinDir       string // dir containing mysql.exe + mysqldump.exe
	MySQLPath    string
	DumpPath     string
	Host         string
	Port         int
	User         string
	Pass         string
	Source       string // where port/user came from
	MySQLVersion string // preferred stack\mysql\<ver> from stack.json
	HasCreds     bool   // true = got user/pass from stack.json/env — don't prompt first try
}

var stdinReader *bufio.Reader // ONE reader for whole program (multiple readers lose buffered input)

func main() {
	fmt.Println("MariaDB Database Manager (Backup/Restore/Audit)")
	fmt.Println("==============================================")
	stdinReader = bufio.NewReader(os.Stdin)

	cfg, err := resolveConfig()
	if err != nil {
		fmt.Printf("[!] Config error: %v\n", err)
		os.Exit(1)
	}

	// 1) binaries exist?
	if err := setupBinaries(cfg); err != nil {
		fmt.Printf("[!] %v\n", err)
		os.Exit(1)
	}

	// 1.5) let user pick/override host:port before login (server=3306, aptstack=3307, …)
	promptTarget(cfg)

	// 2) real login + 3) encoding — retry loop
	if !loginWithRetry(cfg) {
		fmt.Println("Aborting: no valid connection.")
		os.Exit(1)
	}

	for {
		fmt.Println("\nChoose action:")
		fmt.Println("1. List Databases & Backup")
		fmt.Println("2. Restore from .sql.zip")
		fmt.Println("3. List Tables in a Database")
		fmt.Println("4. List Tables with Stats (Rows & Encoding)")
		fmt.Println("5. Exit")
		fmt.Print("Select (1-5): ")

		action := readLine()

		switch action {
		case "1":
			handleBackup(cfg)
		case "2":
			handleRestore(cfg)
		case "3":
			handleListTables(cfg)
		case "4":
			handleTableStats(cfg)
		case "5":
			return
		default:
			fmt.Println("Invalid selection.")
		}
	}
}

func readLine() string {
	line, _ := stdinReader.ReadString('\n')
	return strings.TrimSpace(line)
}

// ---------------------------------------------------------------- resolve config / port

func resolveConfig() (*appConfig, error) {
	cfg := &appConfig{
		Host:   envOr("DB_HOST", "127.0.0.1"),
		Port:   3306, // production server default
		User:   envOr("DB_USER", "root"),
		Pass:   envOr("DB_PASS", ""),
		Source: "default (127.0.0.1:3306)",
	}

	// aptstack stack.json — overrides port/user/pass when present
	if sc, path, ok := loadStackJSON(); ok {
		if sc.DBPort > 0 {
			cfg.Port = sc.DBPort
			cfg.Source = "aptstack " + path
		}
		if sc.DBUser != "" {
			cfg.User = sc.DBUser
			cfg.HasCreds = true
		}
		if sc.DBPass != "" {
			cfg.Pass = sc.DBPass
			cfg.HasCreds = true
		}
		if sc.MySQL != "" {
			cfg.MySQLVersion = sc.MySQL
		}
		fmt.Printf("[i] aptstack config: %s (dbPort=%d dbUser=%s dbMode=%s mysql=%s)\n",
			path, sc.DBPort, sc.DBUser, sc.DBMode, sc.MySQL)
	} else {
		fmt.Println("[i] no aptstack stack.json — using default port 3306")
	}

	// env overrides stack.json
	if v := os.Getenv("DB_PORT"); v != "" {
		if p, err := strconv.Atoi(v); err == nil && p > 0 {
			cfg.Port = p
			cfg.Source = "env DB_PORT"
		}
	}
	if v := os.Getenv("DB_HOST"); v != "" {
		cfg.Host = v
	}
	if v := os.Getenv("DB_USER"); v != "" {
		cfg.User = v
		cfg.HasCreds = true
	}
	if v, ok := os.LookupEnv("DB_PASS"); ok {
		cfg.Pass = v
		cfg.HasCreds = true
	}

	fmt.Printf("[i] target: %s:%d as user '%s' (%s)\n", cfg.Host, cfg.Port, cfg.User, cfg.Source)
	return cfg, nil
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// promptTarget — show current host:port, allow override before connect.
// Accepts: "" (keep) | "3306" (port only) | "host:port" | "host"
func promptTarget(cfg *appConfig) {
	fmt.Printf("\nConnect target [%s:%d]  (Enter=use this, หรือพิมพ์ host:port): ", cfg.Host, cfg.Port)
	fmt.Print("")
	in := readLine()
	if in == "" {
		return
	}
	applyTarget(cfg, in)
	fmt.Printf("[i] target now: %s:%d\n", cfg.Host, cfg.Port)
}

// applyTarget parses "3306" | "127.0.0.1:3306" | "myhost" into cfg.
func applyTarget(cfg *appConfig, in string) {
	in = strings.TrimSpace(in)
	if in == "" {
		return
	}
	// port only
	if p, err := strconv.Atoi(in); err == nil && p > 0 && p <= 65535 && !strings.Contains(in, ":") {
		cfg.Port = p
		cfg.Source = "user input (port)"
		return
	}
	host, portStr, found := strings.Cut(in, ":")
	if found {
		if host != "" {
			cfg.Host = host
		}
		if portStr != "" {
			if p, err := strconv.Atoi(portStr); err == nil && p > 0 && p <= 65535 {
				cfg.Port = p
			} else {
				fmt.Printf("[!] port ไม่ถูกต้อง: %q — คง port เดิม %d\n", portStr, cfg.Port)
			}
		}
		cfg.Source = "user input"
		return
	}
	// host only (no port)
	cfg.Host = in
	cfg.Source = "user input (host)"
}

func loadStackJSON() (*stackConfig, string, bool) {
	// search cwd + parents + executable dir + parents (aptstack root layout)
	var roots []string
	if wd, err := os.Getwd(); err == nil {
		roots = append(roots, wd)
	}
	if exe, err := os.Executable(); err == nil {
		roots = append(roots, filepath.Dir(exe))
	}
	for _, r := range roots {
		dir := r
		for i := 0; i < 6; i++ {
			p := filepath.Join(dir, "config", "stack.json")
			if b, err := os.ReadFile(p); err == nil {
				var sc stackConfig
				if json.Unmarshal(b, &sc) == nil && sc.DBPort > 0 {
					return &sc, p, true
				}
			}
			parent := filepath.Dir(dir)
			if parent == dir {
				break
			}
			dir = parent
		}
	}
	return nil, "", false
}

// ---------------------------------------------------------------- binaries

func setupBinaries(cfg *appConfig) error {
	// Search order:
	//  1) aptstack stack\<mysql-ver>\bin (prefer version from stack.json) — when aptstack layout found
	//  2) PATH (typical production server: mysql on PATH, port 3306)
	//  3) XAMPP common paths
	// Then hard-verify both files exist on disk.
	var aptMysql, aptDump string
	seen := map[string]bool{}
	for _, r := range searchRoots() {
		dir := r
		for i := 0; i < 6; i++ {
			base := filepath.Join(dir, "stack", "mysql")
			matches, _ := filepath.Glob(filepath.Join(base, "*", "bin"))
			for _, binDir := range preferVersion(matches, cfg.MySQLVersion) {
				if aptMysql == "" {
					m := filepath.Join(binDir, "mysql.exe")
					if fileExists(m) {
						aptMysql = m
					}
				}
				if aptDump == "" {
					d := filepath.Join(binDir, "mysqldump.exe")
					if fileExists(d) {
						aptDump = d
					}
				}
			}
			parent := filepath.Dir(dir)
			if parent == dir {
				break
			}
			dir = parent
		}
	}

	var mysqlCands, dumpCands []string
	if aptMysql != "" {
		mysqlCands = append(mysqlCands, aptMysql)
	}
	if aptDump != "" {
		dumpCands = append(dumpCands, aptDump)
	}
	if p, err := exec.LookPath("mysql.exe"); err == nil && !seen[p] {
		seen[p] = true
		mysqlCands = append(mysqlCands, p)
	}
	if p, err := exec.LookPath("mysqldump.exe"); err == nil && !seen[p] {
		seen[p] = true
		dumpCands = append(dumpCands, p)
	}
	for _, dir := range []string{`C:\xampp\mysql\bin`, `D:\xampp\mysql\bin`, `C:\xampp_v8_1_25\mysql\bin`} {
		m := filepath.Join(dir, "mysql.exe")
		d := filepath.Join(dir, "mysqldump.exe")
		if fileExists(m) {
			mysqlCands = append(mysqlCands, m)
		}
		if fileExists(d) {
			dumpCands = append(dumpCands, d)
		}
	}

	for _, c := range mysqlCands {
		if cfg.MySQLPath == "" && fileExists(c) {
			cfg.MySQLPath = c
		}
	}
	for _, c := range dumpCands {
		if cfg.DumpPath == "" && fileExists(c) {
			cfg.DumpPath = c
		}
	}

	if cfg.MySQLPath == "" {
		fmt.Print("mysql.exe not found. Enter full path: ")
		cfg.MySQLPath = readLine()
	}
	if cfg.DumpPath == "" {
		fmt.Print("mysqldump.exe not found. Enter full path: ")
		cfg.DumpPath = readLine()
	}

	if !fileExists(cfg.MySQLPath) {
		return fmt.Errorf("mysql.exe NOT FOUND at: %q (checked aptstack stack\\mysql, PATH, XAMPP)", cfg.MySQLPath)
	}
	if !fileExists(cfg.DumpPath) {
		return fmt.Errorf("mysqldump.exe NOT FOUND at: %q (checked aptstack stack\\mysql, PATH, XAMPP)", cfg.DumpPath)
	}

	cfg.MySQLPath, _ = filepath.Abs(cfg.MySQLPath)
	cfg.DumpPath, _ = filepath.Abs(cfg.DumpPath)

	// version sanity: dump and mysql should come from same major.minor when possible
	fmt.Printf("[+] mysql.exe     : %s\n", cfg.MySQLPath)
	fmt.Printf("[+] mysqldump.exe : %s\n", cfg.DumpPath)
	return nil
}

func searchRoots() []string {
	var roots []string
	if wd, err := os.Getwd(); err == nil {
		roots = append(roots, wd)
	}
	if exe, err := os.Executable(); err == nil {
		roots = append(roots, filepath.Dir(exe))
	}
	return roots
}

// preferVersion — put binDir matching wantVer first; rest sorted descending by path
// (so 10.4.32 before 10.4.8 when no preference — string sort would put 10.4.8 first, so use version compare).
func preferVersion(binDirs []string, wantVer string) []string {
	if len(binDirs) <= 1 {
		return binDirs
	}
	// extract version = parent dir name of ...\mysql\<ver>\bin
	verOf := func(p string) string {
		return filepath.Base(filepath.Dir(p))
	}
	want := strings.ToLower(wantVer)
	out := append([]string{}, binDirs...)
	// simple stable partition: matching want first
	if want != "" {
		var hit, rest []string
		for _, p := range out {
			if strings.ToLower(verOf(p)) == want {
				hit = append(hit, p)
			} else {
				rest = append(rest, p)
			}
		}
		// sort rest by version desc (semver-ish: split on .)
		sortVersionsDesc(rest)
		out = append(hit, rest...)
	} else {
		sortVersionsDesc(out)
	}
	return out
}

func sortVersionsDesc(paths []string) {
	verOf := func(p string) string { return filepath.Base(filepath.Dir(p)) }
	for i := 0; i < len(paths); i++ {
		for j := i + 1; j < len(paths); j++ {
			if compareVersions(verOf(paths[j]), verOf(paths[i])) > 0 {
				paths[i], paths[j] = paths[j], paths[i]
			}
		}
	}
}

func compareVersions(a, b string) int {
	as := strings.Split(a, ".")
	bs := strings.Split(b, ".")
	for i := 0; i < len(as) || i < len(bs); i++ {
		av, bv := 0, 0
		if i < len(as) {
			av, _ = strconv.Atoi(as[i])
		}
		if i < len(bs) {
			bv, _ = strconv.Atoi(bs[i])
		}
		if av != bv {
			if av < bv {
				return -1
			}
			return 1
		}
	}
	return 0
}

func fileExists(p string) bool {
	if p == "" {
		return false
	}
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

// ---------------------------------------------------------------- connection args

// commonArgs — every mysql/mysqldump invocation uses these.
// host+port explicit (3306 server / 3307 aptstack), TCP, utf8mb4, no SSL prompt.
func commonArgs(cfg *appConfig, extra ...string) []string {
	args := []string{
		"-h", cfg.Host,
		"-P", strconv.Itoa(cfg.Port),
		"--protocol=tcp",
		"-u", cfg.User,
		"--default-character-set=utf8mb4",
		"--skip-ssl",
	}
	if cfg.Pass != "" {
		args = append(args, "-p"+cfg.Pass)
	}
	return append(args, extra...)
}

// runCapture — run cmd, return stdout+stderr separately; never hide errors.
func runCapture(bin string, args []string) (stdout, stderr string, exitCode int, err error) {
	cmd := exec.Command(bin, args...)
	var outBuf, errBuf strings.Builder
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf
	runErr := cmd.Run()
	stdout = outBuf.String()
	stderr = errBuf.String()
	if cmd.ProcessState != nil {
		exitCode = cmd.ProcessState.ExitCode()
	}
	if runErr != nil {
		err = runErr
	}
	return
}

// ---------------------------------------------------------------- login + encoding

func loginWithRetry(cfg *appConfig) bool {
	for attempt := 1; attempt <= 10; attempt++ {
		if attempt > 1 {
			fmt.Print("Try again? (y/n): ")
			if strings.ToLower(readLine()) != "y" {
				return false
			}
			fmt.Print("Change target? Enter=keep, or host:port (เช่น 127.0.0.1:3306): ")
			if t := readLine(); t != "" {
				applyTarget(cfg, t)
				fmt.Printf("[i] target now: %s:%d\n", cfg.Host, cfg.Port)
			}
			fmt.Printf("Enter credentials (user/pass) [current: %s@%s:%d]: ", cfg.User, cfg.Host, cfg.Port)
			creds := readLine()
			if creds != "" {
				parseCreds(cfg, creds)
			}
		} else if !cfg.HasCreds {
			// first try and no stack.json/env creds → must ask
			fmt.Printf("Enter credentials (user/pass) [%s@%s:%d]: ", cfg.User, cfg.Host, cfg.Port)
			creds := readLine()
			if creds != "" {
				parseCreds(cfg, creds)
			}
		} else {
			fmt.Printf("[i] using configured credentials (user=%s) — no prompt on first try\n", cfg.User)
		}

		if testLogin(cfg) {
			if checkEncoding(cfg) {
				return true
			}
			fmt.Println("[!] Encoding check failed — will allow retry.")
		} else {
			fmt.Println("[!] Login failed.")
		}
	}
	return false
}

// parseCreds — "user/pass" หรือ "user/pass@host:port"
func parseCreds(cfg *appConfig, creds string) {
	creds = strings.TrimSpace(creds)
	// optional @host:port suffix
	if at := strings.LastIndex(creds, "@"); at > 0 {
		target := creds[at+1:]
		creds = creds[:at]
		applyTarget(cfg, target)
	}
	parts := strings.SplitN(creds, "/", 2)
	cfg.User = parts[0]
	if len(parts) == 2 {
		cfg.Pass = parts[1]
	} else {
		cfg.Pass = ""
	}
	cfg.HasCreds = true
}

// testLogin — real round-trip: SELECT 1 + SHOW variables. Capture server error text.
func testLogin(cfg *appConfig) bool {
	fmt.Printf("\nTesting connection for user '%s' → %s:%d ...\n", cfg.User, cfg.Host, cfg.Port)

	stdout, stderr, code, err := runCapture(cfg.MySQLPath, commonArgs(cfg, "-N", "-B", "-e", "SELECT 1;"))
	if err != nil || code != 0 {
		fmt.Printf("[!] FAILED (exit=%d): %v\n", code, err)
		if strings.TrimSpace(stderr) != "" {
			fmt.Printf("    server said:\n%s\n", indent(stderr))
		}
		return false
	}
	if !strings.Contains(stdout, "1") {
		fmt.Printf("[!] Unexpected response: %q\n", strings.TrimSpace(stdout))
		if strings.TrimSpace(stderr) != "" {
			fmt.Printf("    stderr: %s\n", strings.TrimSpace(stderr))
		}
		return false
	}
	fmt.Println("[+] Connection successful!")
	return true
}

// checkEncoding — verify server/client agree on utf8mb4 (Thai data safety).
func checkEncoding(cfg *appConfig) bool {
	fmt.Println("Checking connection encoding...")
	q := "SHOW VARIABLES WHERE Variable_name IN ('character_set_client','character_set_connection','character_set_results','character_set_server','collation_server');"
	stdout, stderr, code, err := runCapture(cfg.MySQLPath, commonArgs(cfg, "-B", "-e", q))
	if err != nil || code != 0 {
		fmt.Printf("[!] Encoding query failed (exit=%d): %v\n", code, err)
		if strings.TrimSpace(stderr) != "" {
			fmt.Printf("%s\n", indent(stderr))
		}
		return false
	}

	// parse: Variable_name \t Value
	got := map[string]string{}
	for _, line := range strings.Split(stdout, "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" {
			continue
		}
		f := strings.Split(line, "\t")
		if len(f) >= 2 {
			got[f[0]] = f[1]
		}
	}
	if len(got) == 0 {
		fmt.Printf("[!] Encoding variables empty. raw:\n%s\n", stdout)
		return false
	}

	fmt.Println("  encoding variables:")
	warn := false
	for _, k := range []string{"character_set_client", "character_set_connection", "character_set_results", "character_set_server"} {
		v := got[k]
		fmt.Printf("    %-28s = %s\n", k, v)
		// utf8 / utf8mb3 / utf8mb4 all "ok" for reading; utf8mb4 preferred
		if v != "" && !strings.HasPrefix(v, "utf8") && v != "binary" {
			warn = true
			fmt.Printf("      [!] unexpected charset (Thai may break)\n")
		}
	}
	// recommend utf8mb4
	for _, k := range []string{"character_set_client", "character_set_connection", "character_set_results"} {
		if v := got[k]; v != "" && v != "utf8mb4" {
			fmt.Printf("    [i] %s=%s (utf8mb4 preferred for emoji/4-byte)\n", k, v)
		}
	}

	// round-trip Thai string — proves encoding path really works
	fmt.Print("  Thai round-trip test: ")
	if !thaiRoundTrip(cfg) {
		return false
	}
	if warn {
		fmt.Println("[+] Encoding usable, but review warnings above.")
	}
	return true
}

func thaiRoundTrip(cfg *appConfig) bool {
	// Windows: Thai text in -e args gets mangled to '?' via ANSI codepage.
	// Pipe the query on stdin instead — bytes stay UTF-8 end-to-end.
	marker := "ทดสอบภาษาไทยOK"
	query := "SELECT '" + marker + "';\n"

	args := commonArgs(cfg, "-N", "-B")
	cmd := exec.Command(cfg.MySQLPath, args...)
	cmd.Stdin = strings.NewReader(query)
	var outBuf, errBuf strings.Builder
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf
	runErr := cmd.Run()
	code := 0
	if cmd.ProcessState != nil {
		code = cmd.ProcessState.ExitCode()
	}
	if runErr != nil || code != 0 {
		fmt.Printf("FAIL (exit=%d)\n", code)
		if s := strings.TrimSpace(errBuf.String()); s != "" {
			fmt.Printf("    %s\n", s)
		}
		return false
	}
	got := strings.TrimRight(strings.TrimSpace(outBuf.String()), "\r")
	if got != marker {
		fmt.Printf("FAIL — mojibake\n")
		fmt.Printf("    expected: %s\n", marker)
		fmt.Printf("    got     : %q\n", got)
		fmt.Printf("    validUTF8=%v\n", utf8.ValidString(got))
		return false
	}
	if !utf8.ValidString(got) {
		fmt.Println("FAIL — invalid UTF-8")
		return false
	}
	fmt.Println("OK  (utf8 round-trip verified)")
	return true
}

func indent(s string) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	for i, l := range lines {
		lines[i] = "    " + l
	}
	return strings.Join(lines, "\n")
}

// ---------------------------------------------------------------- actions

func handleBackup(cfg *appConfig) {
	dbName := selectDatabase(cfg)
	if dbName == "" {
		return
	}
	backupDB(cfg, dbName)
}

func handleListTables(cfg *appConfig) {
	dbName := selectDatabase(cfg)
	if dbName == "" {
		return
	}
	stdout, stderr, code, err := runCapture(cfg.MySQLPath, commonArgs(cfg, dbName, "-e", "SHOW TABLES;"))
	if err != nil || code != 0 {
		fmt.Printf("Error listing tables (exit=%d): %v\n", code, err)
		if s := strings.TrimSpace(stderr); s != "" {
			fmt.Printf("%s\n", indent(s))
		}
		return
	}
	fmt.Printf("\nTables in %s:\n", dbName)
	for _, line := range strings.Split(stdout, "\n") {
		line = strings.TrimSpace(strings.TrimRight(line, "\r"))
		if line == "" || strings.HasPrefix(line, "Tables_in") {
			continue
		}
		fmt.Printf("  - %s\n", line)
	}
}

func handleTableStats(cfg *appConfig) {
	dbName := selectDatabase(cfg)
	if dbName == "" {
		return
	}
	// escape single quotes in db name for SQL literal
	esc := strings.ReplaceAll(dbName, "'", "''")
	q := "SELECT TABLE_NAME, TABLE_ROWS, TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA = '" + esc + "' ORDER BY TABLE_ROWS DESC;"
	stdout, stderr, code, err := runCapture(cfg.MySQLPath, commonArgs(cfg, "-B", "-e", q))
	if err != nil || code != 0 {
		fmt.Printf("Error fetching stats (exit=%d): %v\n", code, err)
		if s := strings.TrimSpace(stderr); s != "" {
			fmt.Printf("%s\n", indent(s))
		}
		return
	}

	fmt.Printf("\nStats for %s:\n", dbName)
	fmt.Printf("%-40s | %-10s | %s\n", "Table Name", "Rows", "Collation/Encoding")
	fmt.Println(strings.Repeat("-", 80))

	for i, line := range strings.Split(stdout, "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" {
			continue
		}
		parts := strings.Split(line, "\t")
		// -B output has no header when? actually -B includes header — skip first
		if i == 0 && (parts[0] == "TABLE_NAME" || parts[0] == "Table") {
			continue
		}
		name, rows, coll := "", "", ""
		if len(parts) >= 1 {
			name = parts[0]
		}
		if len(parts) >= 2 {
			rows = parts[1]
		}
		if len(parts) >= 3 {
			coll = parts[2]
		}
		if name == "" {
			continue
		}
		fmt.Printf("%-40s | %-10s | %s\n", name, rows, coll)
	}
}

func listDatabases(cfg *appConfig) []string {
	stdout, stderr, code, err := runCapture(cfg.MySQLPath, commonArgs(cfg, "-N", "-B", "-e", "SHOW DATABASES;"))
	if err != nil || code != 0 {
		fmt.Printf("Error listing databases (exit=%d): %v\n", code, err)
		if s := strings.TrimSpace(stderr); s != "" {
			fmt.Printf("%s\n", indent(s))
		}
		return nil
	}
	skip := map[string]bool{
		"information_schema": true,
		"performance_schema": true,
		"mysql":              true,
		"phpmyadmin":         true,
	}
	var dbs []string
	for _, line := range strings.Split(stdout, "\n") {
		line = strings.TrimSpace(strings.TrimRight(line, "\r"))
		if line == "" || skip[line] {
			continue
		}
		dbs = append(dbs, line)
	}
	return dbs
}

func selectDatabase(cfg *appConfig) string {
	dbs := listDatabases(cfg)
	if len(dbs) == 0 {
		fmt.Println("No databases found or connection failed.")
		return ""
	}
	fmt.Println("\nAvailable Databases:")
	for i, db := range dbs {
		fmt.Printf("[%d] %s\n", i+1, db)
	}
	fmt.Printf("\nSelect database (1-%d): ", len(dbs))
	idx := readLine()
	i, err := strconv.Atoi(idx)
	if err != nil || i < 1 || i > len(dbs) {
		fmt.Println("Invalid selection.")
		return ""
	}
	return dbs[i-1]
}

func backupDB(cfg *appConfig, dbName string) {
	timestamp := time.Now().Format("20060102_150405")
	sqlFile := fmt.Sprintf("%s_%s.sql", dbName, timestamp)
	zipFile := sqlFile + ".zip"

	fmt.Printf("Backing up %s to %s...\n", dbName, sqlFile)
	fmt.Printf("  using: %s\n", cfg.DumpPath)
	fmt.Printf("  target: %s:%d\n", cfg.Host, cfg.Port)

	// --single-transaction: consistent InnoDB dump without locking whole DB
	// --routines --triggers: complete backup
	// --hex-blob: varbinary → 0x... (ASCII-safe) กัน charset พังตอน restore
	// --default-character-set=utf8mb4: keep Thai intact
	args := commonArgs(cfg,
		"--single-transaction",
		"--routines",
		"--triggers",
		"--hex-blob",
		"--result-file="+sqlFile,
		dbName,
	)

	stdout, stderr, code, err := runCapture(cfg.DumpPath, args)
	if err != nil || code != 0 {
		fmt.Printf("[!] Error running mysqldump (exit=%d): %v\n", code, err)
		if strings.TrimSpace(stderr) != "" {
			fmt.Printf("    mysqldump said:\n%s\n", indent(stderr))
		}
		if strings.TrimSpace(stdout) != "" {
			fmt.Printf("    stdout:\n%s\n", indent(stdout))
		}
		os.Remove(sqlFile)
		return
	}
	if strings.TrimSpace(stderr) != "" {
		// warnings only
		fmt.Printf("[i] mysqldump warnings:\n%s\n", indent(stderr))
	}

	// verify dump non-empty + UTF-8
	st, statErr := os.Stat(sqlFile)
	if statErr != nil || st.Size() == 0 {
		fmt.Printf("[!] Dump file missing or empty: %s\n", sqlFile)
		os.Remove(sqlFile)
		return
	}
	if !fileIsMostlyUTF8(sqlFile) {
		fmt.Println("[!] WARNING: dump may not be valid UTF-8 — check Thai content after restore")
	}
	fmt.Printf("  dump size: %.1f MB\n", float64(st.Size())/(1024*1024))

	fmt.Printf("Compressing to %s...\n", zipFile)
	if err := zipSingleFile(sqlFile, zipFile); err != nil {
		fmt.Printf("Error zipping: %v\n", err)
		return
	}
	os.Remove(sqlFile)

	absPath, _ := filepath.Abs(zipFile)
	fmt.Printf("Backup successful!\nPath: %s\n", absPath)
}

// fileIsMostlyUTF8 — sample first 256KB; reject if lots of invalid sequences.
func fileIsMostlyUTF8(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	buf := make([]byte, 256*1024)
	n, _ := f.Read(buf)
	if n == 0 {
		return false
	}
	s := string(buf[:n])
	// allow UTF-8 BOM (U+FEFF)
	s = strings.TrimPrefix(s, "\uFEFF")
	return utf8.ValidString(s)
}

func handleRestore(cfg *appConfig) {
	zips, _ := filepath.Glob("*.sql.zip")
	if len(zips) == 0 {
		fmt.Println("No .sql.zip files found in current directory.")
		return
	}
	fmt.Println("\nAvailable Backups:")
	for i, z := range zips {
		fmt.Printf("[%d] %s\n", i+1, z)
	}
	fmt.Printf("\nSelect backup to restore (1-%d): ", len(zips))
	idx := readLine()
	i, err := strconv.Atoi(idx)
	if err != nil || i < 1 || i > len(zips) {
		fmt.Println("Invalid selection.")
		return
	}
	selectedZip := zips[i-1]

	fmt.Print("Enter target database name (will be created if not exists): ")
	dbName := readLine()
	if dbName == "" {
		fmt.Println("Database name cannot be empty.")
		return
	}
	if !isValidIdent(dbName) {
		fmt.Println("Invalid database name (use A-Z a-z 0-9 _ only).")
		return
	}

	// create DB with utf8mb4
	createArgs := commonArgs(cfg, "-e", fmt.Sprintf("CREATE DATABASE IF NOT EXISTS `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;", dbName))
	if _, stderr, code, err := runCapture(cfg.MySQLPath, createArgs); err != nil || code != 0 {
		fmt.Printf("[!] CREATE DATABASE failed (exit=%d): %v\n", code, err)
		if s := strings.TrimSpace(stderr); s != "" {
			fmt.Printf("%s\n", indent(s))
		}
		return
	}

	sqlFile, err := unzipSingleFile(selectedZip)
	if err != nil {
		fmt.Printf("Error unzipping: %v\n", err)
		return
	}
	defer os.Remove(sqlFile)

	if !fileIsMostlyUTF8(sqlFile) {
		fmt.Println("[!] WARNING: .sql file may not be valid UTF-8")
	}

	fmt.Printf("Restoring %s → %s:%d/%s ...\n", sqlFile, cfg.Host, cfg.Port, dbName)

	// pipe file to mysql stdin — more reliable than -e "source ..."
	f, err := os.Open(sqlFile)
	if err != nil {
		fmt.Printf("Error opening dump: %v\n", err)
		return
	}
	defer f.Close()

	// binary charset: dump มี varbinary raw bytes — ห้ามตีความเป็น UTF-8 (มิฉะนั้นโดน U+FFFD)
	args := commonArgs(cfg, dbName)
	for i, a := range args {
		if a == "--default-character-set=utf8mb4" {
			args[i] = "--default-character-set=binary"
		}
	}
	cmd := exec.Command(cfg.MySQLPath, args...)
	cmd.Stdin = f
	var outBuf, errBuf strings.Builder
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf
	runErr := cmd.Run()
	code := 0
	if cmd.ProcessState != nil {
		code = cmd.ProcessState.ExitCode()
	}
	if runErr != nil || code != 0 {
		fmt.Printf("[!] Restore failed (exit=%d): %v\n", code, runErr)
		if s := strings.TrimSpace(errBuf.String()); s != "" {
			fmt.Printf("    mysql said:\n%s\n", indent(s))
		}
		return
	}
	if s := strings.TrimSpace(errBuf.String()); s != "" {
		fmt.Printf("[i] warnings:\n%s\n", indent(s))
	}
	fmt.Println("Restore successful!")
}

func isValidIdent(s string) bool {
	if s == "" {
		return false
	}
	for i, r := range s {
		ok := (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || r == '_' || (i > 0 && r >= '0' && r <= '9')
		if !ok {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------- zip

func zipSingleFile(src, dest string) error {
	zipFile, err := os.Create(dest)
	if err != nil {
		return err
	}
	defer zipFile.Close()

	archive := zip.NewWriter(zipFile)
	defer archive.Close()

	file, err := os.Open(src)
	if err != nil {
		return err
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil {
		return err
	}
	header, err := zip.FileInfoHeader(info)
	if err != nil {
		return err
	}
	header.Name = filepath.Base(src)
	header.Method = zip.Deflate

	writer, err := archive.CreateHeader(header)
	if err != nil {
		return err
	}
	_, err = io.Copy(writer, file)
	return err
}

func unzipSingleFile(src string) (string, error) {
	r, err := zip.OpenReader(src)
	if err != nil {
		return "", err
	}
	defer r.Close()
	if len(r.File) == 0 {
		return "", fmt.Errorf("zip is empty")
	}
	f := r.File[0]
	rc, err := f.Open()
	if err != nil {
		return "", err
	}
	defer rc.Close()

	// safe output name: no path traversal
	base := filepath.Base(f.Name)
	if base == "" || base == "." || base == string(filepath.Separator) {
		return "", fmt.Errorf("bad name in zip: %q", f.Name)
	}
	out, err := os.Create(base)
	if err != nil {
		return "", err
	}
	defer out.Close()
	if _, err := io.Copy(out, rc); err != nil {
		return "", err
	}
	return base, nil
}

// silence unused on non-windows (build tag-free)
var _ = runtime.GOOS
