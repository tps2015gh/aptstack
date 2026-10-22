<?php
/**
 * Router for PHP's built-in server:
 *   php -S 127.0.0.1:8077 -t www www/router.php
 *
 * ---------------------------------------------------------------------------
 * Why this exists
 * ---------------------------------------------------------------------------
 * 1) config.php reads $_SERVER['REQUEST_SCHEME'] as
 *        $is_https = $_SERVER['REQUEST_SCHEME'];
 *        if ($is_https) { 'https://' . $host } else { 'http://' . $host }
 *    That test is truthy for ANY non-empty string, so supplying 'http' would
 *    make every generated URL https:// while our server is plain HTTP.
 *    The built-in server never sets the key at all (which raises an
 *    "Undefined array key" warning). Defining it as '' satisfies isset()
 *    while staying falsy, so config.php takes its http:// branch.
 *
 * 2) CodeIgniter builds its site root as base_url + index_page + '/'  =>  .../index.php/
 *    For a request whose path ends in "index.php/", PHP's built-in server
 *    serves index.php as a STATIC file (empty Content-Type), dumping the raw
 *    PHP source instead of executing it. Apache/mod_php never does this, so
 *    this is purely a built-in-server quirk. Redirect to the same path with
 *    the trailing slash removed; index.php then runs normally.
 *
 * Neither file below (index.php, config.php) is modified by this script.
 */
if (!isset($_SERVER['REQUEST_SCHEME'])) {
	$_SERVER['REQUEST_SCHEME'] = '';
}

$uri  = isset($_SERVER['REQUEST_URI']) ? $_SERVER['REQUEST_URI'] : '/';
$path = parse_url($uri, PHP_URL_PATH);

if ($path !== null && preg_match('#^(.*?/index\.php)/$#', $path, $m)) {
	$qs = parse_url($uri, PHP_URL_QUERY);
	header('Location: ' . $m[1] . (($qs !== null && $qs !== '') ? '?' . $qs : ''), true, 302);
	exit;
}

return false;
