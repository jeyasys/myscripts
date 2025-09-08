<?php
declare(strict_types=1);

/*
  File Manager — cPanel-like, AJAX, Self-Destruct
  - Light theme (clean, table aligned)
  - Scope: current directory only
  - Features: list, inline AJAX rename, delete, mkdir, new file, view/edit text, download
  - Self-destruct: 60s after filemtime(__FILE__) (for testing)
*/

$TITLE = 'Temporary File Manager';
$BASE  = realpath(__DIR__);
$MAX_EDIT_BYTES = 1024 * 1024;
$HARD_DELETE = true;

/* ─ Self-destruct ─ */
$self = __FILE__;
$started = @filemtime($self) ?: time();
$expires_at = $started + 60; // 60s for testing
if (time() > $expires_at) {
    @unlink($self);
    header('Content-Type: text/plain; charset=utf-8');
    exit("This File Manager expired and deleted itself.");
}

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

/* ─ Simple token (no sessions) ─ */
$TOKEN = hash_hmac('sha1',(string)$started,__FILE__);

/* ─ API actions (AJAX) ─ */
if(isset($_GET['api'])){
    header('Content-Type: application/json; charset=utf-8');
    $a=$_GET['api']; $inp=json_decode(file_get_contents('php://input')?:'{}',true);
    if(($inp['token']??'')!==$TOKEN){http_response_code(403);echo '{"ok":false,"error":"token"}';exit;}
    try{
        if($a==='rename'){
            $abs=rel_to_abs($_GET['f']??''); $new=trim($inp['new']??'');
            if($new==='' || strpbrk($new,"/\\")!==false) throw new Exception('bad');
            $dest=dirname($abs).DIRECTORY_SEPARATOR.$new;
            if(file_exists($dest)) throw new Exception('exists');
            if(!@rename($abs,$dest)) throw new Exception('fail');
            echo json_encode(['ok'=>true,'new'=>$new,'rel'=>rel($dest)]);
        }elseif($a==='delete'){
            $abs=rel_to_abs($_GET['f']??'');
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
        }else throw new Exception('bad');
    }catch(Exception $e){http_response_code(400);echo json_encode(['ok'=>false,'error'=>$e->getMessage()]);}
    exit;
}

/* ─ Download / View / Save ─ */
$cwdRel=$_GET['p']??''; $cwdAbs=rel_to_abs($cwdRel);
if(!is_dir($cwdAbs)){$cwdAbs=$BASE;$cwdRel='';}
$act=$_GET['a']??''; $t=$_GET['f']??''; $abs=$t!==''?rel_to_abs($t):'';
if($act==='download'&&is_file($abs)){
    header('Content-Type: application/octet-stream');
    header('Content-Length: '.filesize($abs));
    header('Content-Disposition: attachment; filename="'.basename($abs).'"');
    readfile($abs); exit;
}
if($act==='view'&&is_file($abs)){
  $c=@file_get_contents($abs); $remain=max(0,$expires_at-time());
  $saved = isset($_GET['saved']) && $_GET['saved']==='1';
  ?>
  <!doctype html><meta charset="utf-8">
  <title><?=h($t)?></title>
  <style>body{font:14px Arial;background:#fff;color:#111;margin:0}textarea{width:100%;height:80vh;border:1px solid #ddd;border-radius:6px;padding:8px}</style>
  <div style="padding:10px;background:#f1f1f1;border-bottom:1px solid #ccc">Expires in <span id=cd></span> · <a href="<?=h($_SERVER['PHP_SELF'])?>?p=<?=urlencode(rel(dirname($abs)))?>">Back</a></div>
 <?php if($saved): ?>
  <div style="background:#e6ffed;border:1px solid #b7f5c8;color:#0b6b2e;
              padding:10px;border-radius:6px;margin:10px auto;max-width:1000px;">
    Saved successfully.
  </div>
<?php endif; ?>

<form method=post action="?a=save&f=<?=urlencode(rel($abs))?>" style="padding:10px;max-width:1000px;margin:auto">
    <textarea name=content><?=h($c)?></textarea><br><button>Save</button>
    <a href="?a=download&f=<?=urlencode(rel($abs))?>">Download</a>
  </form>
  <script>let r=<?=$remain?>;function tick(){if(r<0)return;document.getElementById('cd').textContent=(Math.floor(r/60)).toString().padStart(2,'0')+':'+String(r%60).padStart(2,'0');r--;setTimeout(tick,1000);}tick();</script>
  <?php exit;
}
if($_SERVER['REQUEST_METHOD']==='POST'&&$act==='save'&&is_file($abs)){
    $data=(string)($_POST['content']??''); if(strlen($data)>$MAX_EDIT_BYTES) bad('Too large',413);
    if(@file_put_contents($abs,$data)===false) bad('Write failed',500);
    header('Location:?a=view&f='.urlencode(rel($abs)).'&saved=1');exit;
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

<div class="top">Expires in <span id=cd><?=sprintf('%02d:%02d', intdiv($remain,60), $remain%60)?></span></div>

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
            <a class="btn blue" href="?a=view&f=<?=urlencode($f['rel'])?>">View/Edit</a>
            <a class="btn gray" href="?a=download&f=<?=urlencode($f['rel'])?>">Download</a>
          <?php endif; ?>
          <button class="btn gray" onclick="renameItem('<?=h($f['rel'])?>')">Rename</button>
          <button class="btn red" onclick="delItem('<?=h($f['rel'])?>')">Delete</button>
        </td>
      </tr>
    <?php endforeach; ?>
  </table>
</div>

<script>
const TOKEN=<?=json_encode($TOKEN)?>, CURR=<?=json_encode($cwdRel)?>;
let r=<?=json_encode($remain)?>;
(function tick(){ if(r<0) return; const el=document.getElementById('cd'); if(el){el.textContent=(String(Math.floor(r/60)).padStart(2,'0'))+':'+String(r%60).padStart(2,'0');} r--; setTimeout(tick,1000); })();

async function api(a,params={},qs={}) {
  const u = new URL(location.href); u.search = '';
  u.searchParams.set('api',a);
  if(qs.f) u.searchParams.set('f',qs.f);
  if(qs.p) u.searchParams.set('p',qs.p);
  const res = await fetch(u.toString(), {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(Object.assign({token:TOKEN},params))});
  return res.json();
}
function renameItem(rel){ const n=prompt('New name:'); if(!n) return; api('rename',{new:n},{f:rel}).then(j=>{ if(j.ok) location.reload(); else alert('Rename failed'); }); }
function delItem(rel){ if(!confirm('Delete?')) return; api('delete',{}, {f:rel}).then(j=>{ if(j.ok) location.reload(); else alert('Delete failed'); }); }
function mkdir(){ const n=document.getElementById('newFolder').value.trim(); if(!n) return; api('mkdir',{name:n},{p:CURR}).then(j=>{ if(j.ok) location.reload(); else alert('Create folder failed'); }); }
function newfile(){ const n=document.getElementById('newFile').value.trim(); if(!n) return; api('newfile',{name:n},{p:CURR}).then(j=>{ if(j.ok) location.reload(); else alert('Create file failed'); }); }
</script>
