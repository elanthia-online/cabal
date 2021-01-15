LICH_DIR   = Cabal::XDG.path.to_s
TEMP_DIR   = Cabal::XDG.path("temp").to_s
DATA_DIR   = Cabal::XDG.path("data").to_s
SCRIPT_DIR = Cabal::XDG.path("scripts").to_s
MAP_DIR    = Cabal::XDG.path("maps").to_s
LOG_DIR    = Cabal::XDG.path("logs").to_s
BACKUP_DIR = Cabal::XDG.path("backup").to_s

$lich_dir   = LICH_DIR + "/"
$temp_dir   = TEMP_DIR + "/"
$data_dir   = DATA_DIR + "/"
$script_dir = SCRIPT_DIR + "/"
$map_dir    = MAP_DIR + "/"
$log_dir    = LOG_DIR + "/"
$backup_dir = BACKUP_DIR + "/"
$0 = "cabal"
$stdout.sync = true
# lich globals
LICH_VERSION = '4.6.55'.freeze
TESTING = false
$VERBOSE = nil
$link_highlight_start = ''
$link_highlight_end = ''
$speech_highlight_start = ''
$speech_highlight_end = ''
$SEND_CHARACTER = '>'
$cmd_prefix = '<c>'
$clean_lich_char = ';' # fixme
$lich_char = Regexp.escape($clean_lich_char)
# deprecated stuff
$version = LICH_VERSION
$room_count = 0
