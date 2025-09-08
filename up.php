<?php
declare(strict_types=1);

/*
  Temporary AJAX Uploader (self-destructs in 5 minutes)
  - The *script* deletes itself 5 min after its own filemtime(__FILE__)
  - Does NOT delete uploaded files
  - Dark, pill-style UI, progress bar, limit display, dangerous extension block
*/

/* ───────────── Self-destruct (script) ───────────── */
$self       = __FILE__;
$started    = @filemtime($self) ?: time();
$expires_at = $started + 300; // 5 minutes
if (time() > $expires_at) {
    @unlink($self);
    header('Content-Type: text/plain; charset=utf-8');
    exit("This uploader has expired and deleted itself.");
}

/* ───────────── Config / helpers ───────────── */
$BASE  = realpath(__DIR__);
$TOKEN = hash_hmac('sha1', (string)$started, $self); // simple anti-CSRF tied to start time
/* Immediate self-delete */
if (($_GET['kill'] ?? '') === '1') {
    if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['token']) && hash_equals($TOKEN, (string)$_POST['token'])) {
        @unlink(__FILE__);
        header('Content-Type: text/plain; charset=utf-8');
        exit("Uploader deleted.");
    }
    http_response_code(403); exit('Bad token');
}
$dangerous = [
  'sh','exe','bat','cmd','com','scr','pif','msi','vbs','ps1','php','phar',
  'cgi','pl','jar','apk','dll','so','iso','img','bin'
];

function h(string $s): string { return htmlspecialchars($s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'); }
function bad(string $m, int $c=400): never { http_response_code($c); exit($m); }

/* server upload limit helpers */
function bytes_from_ini(string $v): int {
  $v=trim($v); $last=strtolower(substr($v,-1)); $n=(float)$v;
  return $last==='g'?(int)($n*1024*1024*1024):($last==='m'?(int)($n*1024*1024):($last==='k'?(int)($n*1024):(int)$v));
}
function human_bytes(int $n): string {
  if($n>=1073741824) return round($n/1073741824,2).' GB';
  if($n>=1048576)   return round($n/1048576,2).' MB';
  if($n>=1024)      return round($n/1024,2).' KB';
  return $n.' B';
}
$upl  = bytes_from_ini((string)ini_get('upload_max_filesize'));
$post = bytes_from_ini((string)ini_get('post_max_size'));
$effective_limit = min($upl ?: PHP_INT_MAX, $post ?: PHP_INT_MAX);
$limit_h = is_finite($effective_limit) ? human_bytes($effective_limit) : 'unbounded';

/* ───────────── AJAX upload endpoint ───────────── */
if ($_SERVER['REQUEST_METHOD']==='POST' && isset($_GET['upload'])) {
  // hard gate: if expired at POST time, self-delete and fail
  if (time() > $expires_at) {
      @unlink($self);
      bad('Uploader expired', 410);
  }
  if (($_POST['token'] ?? '') !== $TOKEN) bad('Invalid token', 403);
  if (!isset($_FILES['file'])) bad('No file', 400);

  $f = $_FILES['file'];
  if ($f['error'] !== UPLOAD_ERR_OK) bad('Upload error '.$f['error'], 400);

  $orig = basename($f['name']);
  $ext  = strtolower(pathinfo($orig, PATHINFO_EXTENSION));
  if ($ext==='' || in_array($ext,$dangerous,true)) bad('Blocked extension', 400);
  if (is_finite($effective_limit) && (int)$f['size'] > $effective_limit) bad('File too large', 400);

  // Avoid overwrite: keep original name, add numeric suffix if needed
  $safe = preg_replace('/[^A-Za-z0-9._-]+/','_', $orig);
  $dest = $BASE.DIRECTORY_SEPARATOR.$safe;
  for($i=1; file_exists($dest) && $i<10000; $i++){
    $pi = pathinfo($safe);
    $cand = ($pi['filename'] ?? 'file') . "_$i" . (isset($pi['extension'])?('.'.$pi['extension']):'');
    $dest = $BASE.DIRECTORY_SEPARATOR.$cand;
  }

  if(!move_uploaded_file($f['tmp_name'],$dest)) bad('Move failed',500);

  header('Content-Type: application/json');
  echo json_encode(['ok'=>true, 'file'=>basename($dest)]);
  exit;
}
?>
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Temporary Uploader</title>
<style>
:root{
  --bg:#0f1220; --panel:#12172a; --ink:#e6e7ee; --muted:#9aa0b4;
  --accent:#3b82f6; --accent-2:#2563eb; --border:#25304a;
  --ok:#22c55e; --err:#ef4444; --chip:#1f2642;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 system-ui,Segoe UI,Arial,sans-serif}
.wrap{max-width:720px;margin:48px auto;padding:0 18px}
h2{margin:0 0 14px}
.card{background:var(--panel);border:1px solid var(--border);border-radius:14px;padding:16px;box-shadow:0 10px 30px rgba(0,0,0,.35)}
.banner{margin:-6px 0 10px 0;padding:10px 12px;border-radius:10px;border:1px solid rgba(239,68,68,.5);background:rgba(239,68,68,.12);color:#ffd3d3;font-weight:600}
.file{display:flex;align-items:center;gap:10px;border:1px solid var(--accent);border-radius:999px;overflow:hidden;width:100%;max-width:560px;background:#0e214a}
.file-cta{display:inline-flex;align-items:center;gap:8px;background:var(--accent);color:#fff;padding:10px 14px}
.file-cta i{font-style:normal}
.file-name{flex:1;min-height:40px;display:flex;align-items:center;padding:0 12px;background:var(--chip);color:var(--ink);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.file-input{position:absolute;left:-9999px}
.row{display:flex;gap:12px;align-items:center;margin-top:12px;flex-wrap:wrap}
.btn{padding:9px 14px;border-radius:10px;border:1px solid var(--accent);background:var(--accent);color:#fff;cursor:pointer}
.btn:hover{background:var(--accent-2);border-color:var(--accent-2)}
.progress{width:100%;max-width:560px;background:#0e214a;border:1px solid var(--border);border-radius:999px;overflow:hidden;height:18px;margin-top:12px}
.bar{height:100%;width:0;background:var(--accent);color:#fff;text-align:center;font-size:12px;line-height:18px;transition:width .15s ease}
.note{margin-top:10px;color:var(--muted)}
.flash{display:none;margin-top:12px;padding:10px 12px;border-radius:10px;border:1px solid rgba(34,197,94,.5);background:rgba(34,197,94,.12);color:#b9ffd1}
.error{display:none;margin-top:12px;padding:10px 12px;border-radius:10px;border:1px solid rgba(239,68,68,.5);background:rgba(239,68,68,.12);color:#ffbcbc}
.small{font-size:12px;color:var(--muted)}
.path{color:var(--muted);margin-bottom:10px}
.btn.red{background:var(--err);border-color:var(--err)}
.btn.red:hover{background:#c02626;border-color:#c02626}
</style>

<div class="wrap">
<div class="card">
  <div style="display:flex;align-items:center;gap:10px">
    <div class="path" style="margin:0">Destination: <strong><?=h($BASE)?></strong></div>
    <form method="post" action="?kill=1" style="margin-left:auto" onsubmit="return confirm('Delete this uploader script now?');">
      <input type="hidden" name="token" value="<?=h($TOKEN)?>">
      <button class="btn red" type="submit">Delete This Script</button>
    </form>
  </div>
<br><br>
    <!-- Global countdown banner -->
    <div id="globalTimer" class="banner">Uploader expires in <span id="cd">--:--</span></div>

    <label class="file">
      <span class="file-cta"><i>⤴</i><span class="file-label">Choose file…</span></span>
      <input class="file-input" id="file" type="file">
      <span class="file-name" id="filename">No file chosen</span>
    </label>

    <div class="row">
      <button class="btn" id="uploadBtn" onclick="upload()">Upload</button>
    </div>

    <div class="progress"><div class="bar" id="bar"></div></div>
    <div class="note">Max upload size: <strong><?=h($limit_h)?></strong></div>

    <div id="msg" class="flash"></div>
    <div id="err" class="error"></div>
  </div>
</div>

<script>
const TOKEN   = <?=json_encode($TOKEN)?>;
const DANGER  = new Set(<?=json_encode($dangerous)?>);
const LIMIT   = <?=json_encode($effective_limit)?>; // bytes or big number
const REMAIN  = <?=json_encode(max(0,$expires_at - time()))?>; // seconds left for this script

const input   = document.getElementById('file');
const nameEl  = document.getElementById('filename');
const bar     = document.getElementById('bar');
const okBox   = document.getElementById('msg');
const errBox  = document.getElementById('err');
const cdEl    = document.getElementById('cd');
const btn     = document.getElementById('uploadBtn');

input.addEventListener('change', ()=> {
  const f=input.files[0]; nameEl.textContent = f? f.name : 'No file chosen';
});

function human(n){
  if(n>=1073741824) return (n/1073741824).toFixed(2)+' GB';
  if(n>=1048576)   return (n/1048576).toFixed(2)+' MB';
  if(n>=1024)      return (n/1024).toFixed(2)+' KB';
  return n+' B';
}
function ok(m){ okBox.textContent=m; okBox.style.display='block'; }
function err(m){ errBox.textContent=m; errBox.style.display='block'; }

(function countdown(){
  let r = REMAIN;
  function tick(){
    if (r <= 0) {
      cdEl.textContent = '00:00';
      btn.disabled = true; btn.textContent = 'Expired';
      return;
    }
    cdEl.textContent = String(Math.floor(r/60)).padStart(2,'0') + ':' + String(r%60).padStart(2,'0');
    r--; setTimeout(tick, 1000);
  }
  tick();
})();

function upload(){
  okBox.style.display='none'; errBox.style.display='none';
  if (btn.disabled) { err('Uploader expired'); return; }

  const f=input.files[0];
  if(!f){ err('Choose a file'); return; }

  const ext=(f.name.split('.').pop()||'').toLowerCase();
  if(!ext || DANGER.has(ext)){ err('Blocked extension: .' + (ext||'(none)')); return; }
  if(Number.isFinite(LIMIT) && f.size>LIMIT){ err('Too large. Max: '+human(LIMIT)); return; }

  const xhr=new XMLHttpRequest();
  xhr.open('POST','?upload=1');
  const form=new FormData();
  form.append('file',f); form.append('token',TOKEN);

  bar.style.width='0%'; bar.textContent='0%';
  xhr.upload.onprogress=(e)=>{ if(e.lengthComputable){ const p=Math.round(e.loaded/e.total*100); bar.style.width=p+'%'; bar.textContent=p+'%'; }};
  xhr.onload=()=> {
    if(xhr.status===200){
      try{
        const j=JSON.parse(xhr.responseText);
        if(j.ok){ ok('Uploaded: '+j.file); bar.style.width='100%'; bar.textContent='100%'; }
        else err(j.error||'Upload failed');
      }catch(e){ err('Bad response'); }
    } else if (xhr.status===410){
      err('Uploader expired (script removed).');
      btn.disabled = true; btn.textContent = 'Expired';
    } else err('HTTP '+xhr.status);
  };
  xhr.onerror=()=> err('Network error');
  xhr.send(form);
}
</script>
