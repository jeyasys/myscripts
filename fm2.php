<?php
declare(strict_types=1);

/*
  File Manager — cPanel-like, AJAX, Self-Destruct
  - Light theme (clean, table aligned)
  - Scope: current directory only
  - Features: list, inline AJAX rename, delete, mkdir, new file, view/edit text, download
  - Self-destruct: 5 min after filemtime(__FILE__) (auto-delete even without a browser revisit)
  - NEW:
      * "Extend +5 min" button (touches file, resets token & countdown)
      * Background auto-deleter with fallback to post-response sleeper
*/

$TITLE = 'Temporary File Manager';
$BASE  = realpath(__DIR__);
$MAX_EDIT_BYTES = 1024 * 1024;

/* ─ Paths & self ─ */
$self = __FILE__;

/* ─ Helpers ─ */
function h(string $s): string { return htmlspecialchars($s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'); }
function bad(string $m, int $code=400): void { http_response_code($code); echo $m; exit; }

function rel_to_abs(string $rel): string {
    global $BASE;
    $rel = trim($rel, "/\\");
    $path = $rel==='' ? $BASE : $BASE.DIRECTORY_SEPARATOR.$rel;
    $real = realpath($path);
    if ($real===false) $real=$path;
    $basePrefix = rtrim($BASE, DIRECTORY_SEPARATOR).DIRECTORY_SEPARATOR;
    $test = rtrim($real, DIRECTORY_SEPARATOR).DIRECTORY_SEPARATOR;
    if (strpos($real, $BASE)===0 || strpos($test, $basePrefix)===0) return $real;
    bad('Path escape blocked', 403);
}
function rel(string $abs): string {
    global $BASE; return ltrim(substr($abs, strlen($BASE)), DIRECTORY_SEPARATOR);
}
function bytes_h(int $b): string {
    $u=['B','KB','MB','GB','TB']; $i=0;
    while ($b>=1024 && $i<count($u)-1){$b/=1024;$i++;}
    return round($b,2).' '.$u[$i];
}
function list_dir(string $dir): array {
    $out=['dirs'=>[],'files'=>[]];
    foreach(scandir($dir)?:[] as $it){
        if($it==='.'||$it==='..') continue;
        $p=$dir.DIRECTORY_SEPARATOR.$it; $isDir=is_dir($p);
        $out[$isDir?'dirs':'files'][]=[
            'name'=>$it,'rel'=>rel($p),'size'=>$isDir?0:(int)@filesize($p),
            'mtime'=>(int)@filemtime($p),'perm'=>substr(decoct(@fileperms($p)&0777),-3),
            'isdir'=>$isDir
        ];
    }
    usort($out['dirs'],fn($a,$b)=>strcasecmp($a['name'],$b['name']));
    usort($out['files'],fn($a,$b)=>strcasecmp($a['name'],$b['name']));
    return $out;
}
function rmdir_recursive(string $d): bool {
    if(!is_dir($d)) return @unlink($d);
    foreach(scandir($d)?:[] as $it){
        if($it==='.'||$it==='..') continue;
        $p=$d.DIRECTORY_SEPARATOR.$it;
        if(is_dir($p)) { if(!rmdir_recursive($p)) return false; }
        else if(!@unlink($p)) return false;
    }
    return @rmdir($d);
}

/* base64url helpers to hide filenames in query */
function b64e(string $s): string { return rtrim(strtr(base64_encode($s), '+/', '-_'), '='); }
function b64d(string $s): string {
    $s = strtr($s, '-_', '+/'); $pad = strlen($s) % 4; if ($pad) $s .= str_repeat('=', 4 - $pad);
    return base64_decode($s) ?: '';
}

/* ─ Self-destruct timing & token ─ */
$expires_after = 1500; // 5 minutes
$started = @filemtime($self) ?: time();
$expires_at = $started + $expires_after;

/* Simple HMAC token bound to filemtime */
$TOKEN = hash_hmac('sha1',(string)$started,$self);

/* ─ Capability checks ─ */
function func_disabled(string $fn): bool {
    if (!function_exists($fn)) return true;
    $disabled = array_map('trim', explode(',', (string)ini_get('disable_functions')));
    return in_array($fn, $disabled, true);
}
function can_detach_process(): bool {
    if (ini_get('safe_mode')) return false; // legacy, but be safe
    if (func_disabled('proc_open') || func_disabled('proc_close') || func_disabled('escapeshellarg')) return false;
    return true;
}

/* ─ Detached background deleter ─ */
function spawn_auto_delete(string $file, int $seconds, int $grace=2): bool {
    if ($seconds < 0) $seconds = 0;
    if (!can_detach_process()) return false;

    $php    = PHP_BINARY ?: 'php';
    $fileQ  = escapeshellarg($file);
    $sleepS = (string)max(0, $seconds);
    $graceS = (string)max(0, $grace);

    $inline = <<<PHPCMD
@\\sleep($sleepS + $graceS);
\$f=$fileQ;
@\\clearstatcache(true,\$f);
\$s=@\\filemtime(\$f);
if(\$s && (time() > \$s + 300)) { @\\unlink(\$f); }
PHPCMD;

    $cmd = escapeshellarg($php).' -r '.escapeshellarg($inline);
    $sh = 'nohup sh -c '.escapeshellarg($cmd).' >/dev/null 2>&1 &';

    $proc = @proc_open($sh, [0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']], $pipes);
    if (is_resource($proc)) { @proc_close($proc); return true; }
    return false;
}

/* ─ Inline post-response sleeper fallback ─
   Sends the HTTP response, then keeps the PHP worker alive to sleep and delete.
   This guarantees deletion even on locked-down hosts, at the cost of one worker.
*/
function start_inline_sleeper(string $file, int $seconds): void {
    if ($seconds < 0) $seconds = 0;

    // Finish the response cleanly so the browser is not held
    if (!headers_sent()) {
        header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
        header('Pragma: no-cache');
        header('Connection: close');
    }
    // Flush all output buffers
    while (ob_get_level() > 0) { @ob_end_flush(); }
    @flush();

    // If available, tell FPM/FastCGI we’re done with the client
    if (function_exists('fastcgi_finish_request')) {
        @fastcgi_finish_request();
    }

    @ignore_user_abort(true);
    @set_time_limit($seconds + 10);

    @sleep($seconds + 2);
    @clearstatcache(true, $file);
    $s = @filemtime($file);
    if ($s && (time() > $s + 300)) { @unlink($file); }
}

/* ─ Ensure an auto-delete is scheduled for this request ─ */
$remain_now = max(0, $expires_at - time());
$detached_ok = spawn_auto_delete($self, $remain_now);
/* If detached spawner is blocked, we rely on inline sleeper.
   We'll start it at the very end of the request, after rendering. */

/* ─ Immediate self-delete endpoint ─ */
if (($_GET['kill'] ?? '') === '1') {
    if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['token']) && hash_equals($TOKEN, (string)$_POST['token'])) {
        @unlink($self);
        header('Content-Type: text/plain; charset=utf-8');
        echo "File manager deleted.";
        // No need for sleeper here; we’re gone.
        exit;
    }
    http_response_code(403); exit('Bad token');
}

/* ─ Expiry gate (hard stop if already expired) ─ */
if (time() > $expires_at) {
    @unlink($self);
    header('Content-Type: text/plain; charset=utf-8');
    exit("This File Manager expired and deleted itself.");
}

/* ─ API actions (AJAX) ─ */
if(isset($_GET['api'])){
    header('Content-Type: application/json; charset=utf-8');
    $a=$_GET['api']; $inp=json_decode(file_get_contents('php://input')?:'{}',true);
    if(($inp['token']??'')!==$TOKEN){http_response_code(403);echo '{"ok":false,"error":"token"}';exit;}
    try{
        if($a==='rename'){
            $gf = $_GET['f'] ?? '';
            if (($_GET['enc'] ?? '') === '1') $gf = b64d($gf);
            $abs=rel_to_abs($gf); $new=trim($inp['new']??'');
            if($new==='' || strpbrk($new,"/\\")!==false) throw new Exception('bad');
            $dest=dirname($abs).DIRECTORY_SEPARATOR.$new;
            if(file_exists($dest)) throw new Exception('exists');
            if(!@rename($abs,$dest)) throw new Exception('fail');
            echo json_encode(['ok'=>true,'new'=>$new,'rel'=>rel($dest)]);

        }elseif($a==='delete'){
            $gf = $_GET['f'] ?? '';
            if (($_GET['enc'] ?? '') === '1') $gf = b64d($gf);
            $abs=rel_to_abs($gf);
            $ok=is_dir($abs)?rmdir_recursive($abs):@unlink($abs);
            if(!$ok) throw new Exception('fail'); echo'{"ok":true}';

        }elseif($a==='mkdir'){
            $cwd=rel_to_abs($_GET['p']??''); $n=trim($inp['name']??'');
            if($n==='' || strpbrk($n,"/\\")!==false) throw new Exception('bad');
            if(!@mkdir($cwd.DIRECTORY_SEPARATOR.$n,0755)) throw new Exception('fail'); echo'{"ok":true}';

        }elseif($a==='newfile'){
            $cwd=rel_to_abs($_GET['p']??''); $n=trim($inp['name']??'');
            if($n==='' || strpbrk($n,"/\\")!==false) throw new Exception('bad');
            if(@file_put_contents($cwd.DIRECTORY_SEPARATOR.$n,'')===false) throw new Exception('fail'); echo'{"ok":true}';

        }elseif($a==='extend'){
            // Touch file to "now" to reset the 5-minute window and rotate token
            $now = time();
            if (!@touch($self, $now)) throw new Exception('fail');

            // Re-spawn background deleter for the new window; fallback handled at end of request
            spawn_auto_delete($self, 300);

            $newToken = hash_hmac('sha1', (string)$now, $self);
            echo json_encode(['ok'=>true,'remain'=>300,'token'=>$newToken]);

        }else throw new Exception('bad');

    }catch(Exception $e){
        http_response_code(400);
        echo json_encode(['ok'=>false,'error'=>$e->getMessage()]);
    }
    // Start inline sleeper if no detached process was possible
    if (!$detached_ok) start_inline_sleeper($self, max(0, ($started + 300) - time()));
    exit;
}

/* ─ Download / View / Save ─ */
$cwdRel=$_GET['p']??''; $cwdAbs=rel_to_abs($cwdRel);
if(!is_dir($cwdAbs)){$cwdAbs=$BASE;$cwdRel='';}
$act=$_GET['a']??''; $t=$_GET['f']??'';
if (($_GET['enc'] ?? '') === '1') $t = b64d($t);
$abs=$t!==''?rel_to_abs($t):'';

if($act==='download'&&is_file($abs)){
    header('Content-Type: application/octet-stream');
    header('Content-Length: '.filesize($abs));
    header('Content-Disposition: attachment; filename="'.basename($abs).'"');
    readfile($abs);
    if (!$detached_ok) start_inline_sleeper($self, max(0, ($started + 300) - time()));
    exit;
}

if($act==='view'&&is_file($abs)){
  $c=@file_get_contents($abs); $remain=max(0,$expires_at-time());
  $saved = isset($_GET['saved']) && $_GET['saved']==='1';
  ?>
  <!doctype html><meta charset="utf-8">
  <title><?=h($t)?></title>
  <style>
    body{font:14px Arial;background:#fff;color:#111;margin:0}
    textarea{width:100%;height:80vh;border:1px solid #ddd;border-radius:6px;padding:8px}
    .btn{padding:4px 8px;border-radius:4px;font-size:12px;text-decoration:none;cursor:pointer}
    .blue{background:#0d6efd;color:#fff;border:1px solid #0d6efd}
    .blue:hover{background:#0b5ed7}
  </style>
  <div style="padding:10px;background:#f1f1f1;border-bottom:1px solid #ccc;display:flex;align-items:center;gap:10px">
    <div>Expires in <span id=cd></span></div>
    <button class="btn blue" type="button" onclick="extendExpiry()">Extend +5 min</button>
    <div style="margin-left:auto"><a href="<?=h($_SERVER['PHP_SELF'])?>?p=<?=urlencode(rel(dirname($abs)))?>">Back</a></div>
  </div>

 <?php if($saved): ?>
  <div style="background:#e6ffed;border:1px solid #b7f5c8;color:#0b6b2e;
              padding:10px;border-radius:6px;margin:10px auto;max-width:1000px;">
    Saved successfully.
  </div>
<?php endif; ?>

<form method=post action="?a=save&enc=1&f=<?=h(b64e(rel($abs)))?>" style="padding:10px;max-width:1000px;margin:auto">
    <textarea name=content><?=h($c)?></textarea><br><button>Save</button>
    <a href="?a=download&enc=1&f=<?=h(b64e(rel($abs)))?>">Download</a>
  </form>
  <script>
    let r = <?=$remain?>;
    function tick(){
      if(r<0) return;
      document.getElementById('cd').textContent=(Math.floor(r/60)).toString().padStart(2,'0')+':'+String(r%60).padStart(2,'0');
      r--; setTimeout(tick,1000);
    }
    tick();

    let TOKEN = <?=json_encode($TOKEN)?>;
    async function extendExpiry(){
      try{
        const u = new URL(location.href);
        u.search = '';
        u.searchParams.set('api','extend');
        const res = await fetch(u.toString(), {
          method:'POST',
          headers:{'Content-Type':'application/json'},
          body: JSON.stringify({token: TOKEN})
        });
        const j = await res.json();
        if(j && j.ok){
          TOKEN = j.token;
          r = j.remain;
        }else{
          alert('Extend failed');
        }
      }catch(e){ alert('Extend failed'); }
    }
  </script>
  <?php
  // Begin inline sleeper if needed
  if (!$detached_ok) start_inline_sleeper($self, max(0, ($started + 300) - time()));
  exit;
}

if($_SERVER['REQUEST_METHOD']==='POST'&&$act==='save'&&is_file($abs)){
    $data=(string)($_POST['content']??''); if(strlen($data)>$MAX_EDIT_BYTES) bad('Too large',413);
    if(@file_put_contents($abs,$data)===false) bad('Write failed',500);
    header('Location:?a=view&enc=1&f='.rawurlencode(b64e(rel($abs))).'&saved=1');
    if (!$detached_ok) start_inline_sleeper($self, max(0, ($started + 300) - time()));
    exit;
}

/* ─ Listing ─ */
$list=list_dir($cwdAbs); $remain=max(0,$expires_at-time());
?>
<!doctype html><meta charset="utf-8">
<title><?=h($TITLE)?></title>
<style>
body{font:14px Arial,Helvetica,sans-serif;background:#fff;color:#111;margin:0}
.top{background:#f1f1f1;border-bottom:1px solid #ccc;padding:10px}
.wrap{max-width:1000px;margin:20px auto;padding:0 10px}
table{width:100%;border-collapse:collapse}
th,td{padding:8px;border:1px solid #ddd;text-align:left}
th{background:#f9f9f9}
.btn{padding:4px 8px;border-radius:4px;font-size:12px;text-decoration:none;cursor:pointer}
.blue{background:#0d6efd;color:#fff;border:1px solid #0d6efd}
.blue:hover{background:#0b5ed7}
.red{background:#dc3545;color:#fff;border:1px solid #dc3545}
.red:hover{background:#bb2d3b}
.gray{background:#6c757d;color:#fff;border:1px solid #6c757d}
.gray:hover{background:#5c636a}
input.inline{padding:6px;border:1px solid #ddd;border-radius:4px}
.meta{color:#555;margin:8px 0}
a.link{color:#0d6efd;text-decoration:none}
</style>

<div class="top" style="display:flex;align-items:center;gap:10px">
  <div>Expires in <span id=cd><?=sprintf('%02d:%02d', intdiv($remain,60), $remain%60)?></span></div>
  <button class="btn blue" type="button" onclick="extendExpiry()">Extend +5 min</button>
  <form method="post" action="?kill=1" style="margin-left:auto" onsubmit="return confirm('Delete this file manager script now?');">
    <input type="hidden" name="token" value="<?=h($TOKEN)?>">
    <button class="btn red" type="submit">Delete This Script</button>
  </form>
</div>
<br><br>
<div class="wrap">
  <div class="meta">Working dir: <?=h($BASE)?><?php if($cwdRel!==''):?> / <?=h($cwdRel)?><?php endif;?></div>

  <div style="margin:10px 0">
    <input class="inline" id="newFolder" placeholder="New folder">
    <button class="btn blue" onclick="mkdir()">Create Folder</button>
    <input class="inline" id="newFile" placeholder="New file.txt" style="margin-left:8px">
    <button class="btn blue" onclick="newfile()">Create File</button>
  </div>

  <table>
    <tr><th>Name</th><th>Size</th><th>Modified</th><th>Perm</th><th>Actions</th></tr>
    <?php if($cwdRel!==''): ?>
      <tr>
        <td><a class="link" href="<?=h($_SERVER['PHP_SELF'])?>?p=<?=rawurlencode(rel(dirname($cwdAbs)))?>">.. (parent)</a></td>
        <td></td><td></td><td></td><td></td>
      </tr>
    <?php endif; ?>

    <?php foreach(array_merge($list['dirs'],$list['files']) as $f): ?>
      <tr data-rel="<?=h($f['rel'])?>">
        <td>
          <?php if($f['isdir']): ?>
            <a class="link" href="?p=<?=urlencode($f['rel'])?>"><?=h($f['name'])?></a>
          <?php else: ?>
            <?=h($f['name'])?>
          <?php endif; ?>
        </td>
        <td><?=$f['isdir']?'—':bytes_h($f['size'])?></td>
        <td><?=date('Y-m-d H:i:s',$f['mtime'])?></td>
        <td><?=h($f['perm'])?></td>
        <td>
          <?php if(!$f['isdir']): ?>
            <a class="btn blue" href="?a=view&enc=1&f=<?=h(b64e($f['rel']))?>">View/Edit</a>
            <a class="btn gray" href="?a=download&enc=1&f=<?=h(b64e($f['rel']))?>">Download</a>
          <?php endif; ?>
          <button class="btn gray" onclick="renameItem('<?=h($f['rel'])?>')">Rename</button>
          <button class="btn red" onclick="delItem('<?=h($f['rel'])?>')">Delete</button>
        </td>
      </tr>
    <?php endforeach; ?>
  </table>
</div>

<script>
let TOKEN=<?=json_encode($TOKEN)?>, CURR=<?=json_encode($cwdRel)?>;
let r=<?=json_encode($remain)?>;
(function tick(){ if(r<0) return; const el=document.getElementById('cd'); if(el){el.textContent=(String(Math.floor(r/60)).padStart(2,'0'))+':'+String(r%60).padStart(2,'0');} r--; setTimeout(tick,1000); })();

async function api(a,params={},qs={}) {
  const u = new URL(location.href); u.search = '';
  u.searchParams.set('api',a);
  if(qs.f)   u.searchParams.set('f',qs.f);
  if(qs.p)   u.searchParams.set('p',qs.p);
  if(qs.enc) u.searchParams.set('enc',qs.enc);
  const res = await fetch(u.toString(), {
    method:'POST',
    headers:{'Content-Type':'application/json'},
    body:JSON.stringify(Object.assign({token:TOKEN},params))
  });
  return res.json();
}

// base64url from JS
function b64e(s){
  return btoa(unescape(encodeURIComponent(s))).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
}

function renameItem(rel){
  const n=prompt('New name:'); if(!n) return;
  api('rename',{new:n},{enc:'1', f:b64e(rel)}).then(j=>{
    if(j.ok) location.reload(); else alert('Rename failed');
  });
}
function delItem(rel){
  if(!confirm('Delete?')) return;
  api('delete',{}, {enc:'1', f:b64e(rel)}).then(j=>{
    if(j.ok) location.reload(); else alert('Delete failed');
  });
}
function mkdir(){
  const n=document.getElementById('newFolder').value.trim(); if(!n) return;
  api('mkdir',{name:n},{p:CURR}).then(j=>{
    if(j.ok) location.reload(); else alert('Create folder failed');
  });
}
function newfile(){
  const n=document.getElementById('newFile').value.trim(); if(!n) return;
  api('newfile',{name:n},{p:CURR}).then(j=>{
    if(j.ok) location.reload(); else alert('Create file failed');
  });
}

async function extendExpiry(){
  try{
    const j = await api('extend');
    if (j && j.ok) {
      TOKEN = j.token;
      r = j.remain; // reset the countdown to 300 seconds
    } else {
      alert('Extend failed');
    }
  }catch(e){
    alert('Extend failed');
  }
}
</script>
<?php
// Start inline sleeper at the very end if we couldn't detach a background process
if (!$detached_ok) start_inline_sleeper($self, max(0, ($started + 300) - time()));
