import { randomBytes } from 'node:crypto';
import { mkdir, writeFile, stat } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import path from 'node:path';
const CACHE=process.env.MUSIC_CACHE||'/root/workspace/run/music-playback-research/verified-cache';
await mkdir(CACHE,{recursive:true});
const results=new Map(),pending=new Map(),media=new Map();
const headers={'User-Agent':'Mozilla/5.0','Referer':'https://y.qq.com/'};
export class PlaybackError extends Error {constructor(message,code='UNAVAILABLE'){super(message);this.code=code;}}
async function json(url){const r=await fetch(url,{headers,signal:AbortSignal.timeout(16000)});if(!r.ok)throw new PlaybackError('上游 HTTP '+r.status,'UPSTREAM');return r.json();}
async function qq(module,method,param){const data={comm:{uin:0,format:'json',ct:24,cv:0},req_0:{module,method,param}};const d=await json('https://u.y.qq.com/cgi-bin/musicu.fcg?data='+encodeURIComponent(JSON.stringify(data)));if(d.req_0?.code!==0)throw new PlaybackError('QQ 官方接口暂时不可用','UPSTREAM');return d.req_0.data;}
export async function official(source,id){
 if(source==='tencent'){
  if(!/^[a-zA-Z0-9]{8,20}$/.test(id))throw new PlaybackError('无效的 QQ 歌曲标识','PARAM');
  const {track_info:t}=await qq('music.pf_song_detail_svr','get_song_detail_yqq',{song_mid:id});
  if(!t)throw new PlaybackError('QQ 未返回曲目资料','UPSTREAM');
  const meta={source,id,name:t.title||t.name,artist:(t.singer||[]).map(x=>x.name).join('/'),album:t.album?.title||t.album?.name||'',expectedDuration:Number(t.interval),pic:''};
  const d=await qq('music.vkey.GetVkey','UrlGetVkey',{uin:'0',filename:['M500'+(t.file?.media_mid||id+id)+'.mp3'],guid:String(Math.floor(1e9+Math.random()*8e9)),songmid:[id],songtype:[0],ctx:0});
  const purl=d.midurlinfo?.[0]?.purl;
  if(!purl)return {...meta,unavailable:true,reason:'QQ 当前账号未获得这首歌的完整播放地址'};
  const base=d.sip?.find(x=>x.startsWith('https://'))||d.sip?.[0]||'https://isure.stream.qqmusic.qq.com/';
  return {...meta,url:new URL(purl,base).href};
 }
 if(source==='kugou'){
  if(!/^[a-fA-F0-9]{32}$/.test(id))throw new PlaybackError('无效的酷狗歌曲标识','PARAM');
  const d=await json('https://m.kugou.com/api/v1/song/get_song_info?hash='+id+'&cmd=playInfo');
  const extra=d.extra||{};
  const meta={source,id,name:d.songName||d.songname||'',artist:d.singerName||d.singername||'',expectedDuration:Number(d.timeLength)||(Number(extra['128timelength'])/1000)||0,album:d.album_name||''};
  const url=d.url||(Array.isArray(d.backup_url)?d.backup_url.find(x=>typeof x==='string'):Object.values(d.backup_url||{}).find(x=>typeof x==='string'&&x.startsWith('http')));
  return url?{...meta,url}:{...meta,unavailable:true,reason:d.error||'酷狗未提供完整播放地址'};
 }
 if(source==='netease'){
  if(!/^\d{1,18}$/.test(id))throw new PlaybackError('无效的网易歌曲标识','PARAM');
  const d=await json('https://music.163.com/api/song/detail?'+new URLSearchParams({id,ids:JSON.stringify([id])}));
  const t=d.songs?.[0];if(!t)throw new PlaybackError('网易未返回曲目资料','UPSTREAM');
  const urls=['https://api.qijieya.cn/meting/','https://api.injahow.cn/meting/'].map(host=>host+'?'+new URLSearchParams({server:'netease',type:'url',id}));
  return {source,id,name:t.name,artist:(t.artists||t.ar||[]).map(a=>a.name).join('/'),album:t.album?.name||t.al?.name||'',expectedDuration:Number(t.duration||t.dt)/1000,url:urls[0],urls};
 }
 throw new PlaybackError('不支持的音乐源','PARAM');
}
function command(program,args,timeout=30000){return new Promise((resolve,reject)=>{const p=spawn(program,args,{stdio:['ignore','pipe','pipe']});let out='',err='';const timer=setTimeout(()=>p.kill('SIGKILL'),timeout);p.stdout.on('data',b=>out+=b);p.stderr.on('data',b=>err+=b);p.on('error',e=>{clearTimeout(timer);reject(e);});p.on('close',code=>{clearTimeout(timer);if(code===0)resolve(out);else reject(new PlaybackError(program+' 音频核验失败: '+err.slice(-180),'INVALID_AUDIO'));});});}
function allowedAudio(url){const u=new URL(url);return u.protocol==='https:'||u.protocol==='http:';}
async function download(meta){
 if(!meta.url||!allowedAudio(meta.url))throw new PlaybackError('没有可用的完整音频地址');
 const r=await fetch(meta.url,{headers:meta.headers||headers,signal:AbortSignal.timeout(45000)});
 if(!r.ok)throw new PlaybackError('音频文件 HTTP '+r.status,'UPSTREAM');
 const chunks=[];let size=0;for await(const b of r.body){size+=b.length;if(size>40*1024*1024){await r.body.cancel().catch(()=>{});throw new PlaybackError('音频文件超过 40MB 限制','SIZE');}chunks.push(b);}
 if(size<4096)throw new PlaybackError('上游返回空文件或错误内容','INVALID_AUDIO');
 const token=randomBytes(18).toString('hex'),file=path.join(CACHE,token+'.audio');
 await writeFile(file,Buffer.concat(chunks));
 const info=JSON.parse(await command('ffprobe',['-v','error','-show_entries','format=duration:stream=codec_type,codec_name','-of','json',file]));
 const duration=Number(info.format?.duration);
 if(!info.streams?.some(s=>s.codec_type==='audio')||!Number.isFinite(duration)||duration<10)throw new PlaybackError('文件不是可播放歌曲','INVALID_AUDIO');
 const tol=meta.durationTolerance||Math.max(4,meta.expectedDuration*.025);
 if(!meta.expectedDuration&&!meta.verifyTags)throw new PlaybackError('音频时长与原曲不符，已拒绝试听或错误版本','DURATION_MISMATCH');
 if(meta.expectedDuration&&Math.abs(duration-meta.expectedDuration)>tol)throw new PlaybackError('音频时长与原曲不符，已拒绝试听或错误版本','DURATION_MISMATCH');
 if(meta.verifyTags){
  const tags=(info.format&&info.format.tags)||{};
  const tt=String(tags.title||tags.TITLE||''),ta=String(tags.artist||tags.ARTIST||'');
  if(tt&&!looseName(tt,meta.verifyTags.title))throw new PlaybackError('音频标签与目标歌曲不符，已拒绝','INVALID_AUDIO');
  if(ta&&artistSet(ta)!==artistSet(meta.verifyTags.artist))throw new PlaybackError('音频标签歌手与目标不符，已拒绝','INVALID_AUDIO');
 }
 await command('ffmpeg',['-v','error','-xerror','-i',file,'-vn','-f','null','-']);
 await command('ffmpeg',['-v','error','-xerror','-sseof','-8','-i',file,'-t','5','-vn','-f','null','-']);
 const codec=info.streams.find(s=>s.codec_type==='audio').codec_name;
 media.set(token,{file,size,mime:codec==='mp3'?'audio/mpeg':codec==='flac'?'audio/flac':'audio/mp4'});
 return {source:meta.source,id:meta.id,name:meta.name,artist:meta.artist,album:meta.album||'',duration,expectedDuration:meta.expectedDuration,size,codec,verifiedFull:true,fullDecoded:true,tailDecoded:true,url:'/media/'+token,substituted:!!meta.substituted};
}
const normalize=x=>String(x||'').normalize('NFKC').toLowerCase().replace(/[\s·.,，。!?！？、_\-]/g,'');
const artistSet=x=>String(x||'').split(/[/、&,，]/).map(normalize).filter(Boolean).sort().join('|');
const T2S={'澗':'涧','愛':'爱','聽':'听','夢':'梦','傷':'伤','淚':'泪','風':'风','雲':'云','龍':'龙','鳳':'凤','國':'国','學':'学','樂':'乐','歡':'欢','氣':'气','無':'无','時':'时','間':'间','東':'东','車':'车','馬':'马','鳥':'鸟','魚':'鱼','頭':'头','發':'发','電':'电','飛':'飞','靈':'灵','靜':'静','聲':'声','讀':'读','寫':'写','軍':'军','與':'与','從':'从','當':'当','會':'会','圖':'图','號':'号','詞':'词','線':'线','點':'点','體':'体','樣':'样','種':'种','給':'给','讓':'让','說':'说','話':'话','誰':'谁','這':'这','後':'后','對':'对','開':'开','關':'关','門':'门','問':'问','買':'买','賣':'卖','貴':'贵','錢':'钱','銀':'银','鐵':'铁','鋼':'钢','錄':'录','歸':'归','歲':'岁','舊':'旧','懷':'怀','憶':'忆','戀':'恋','態':'态','應':'应','該':'该','總':'总','個':'个','幾':'几','處':'处','場':'场','鄉':'乡','鄭':'郑','陳':'陈','劉':'刘','張':'张','楊':'杨','黃':'黄','趙':'赵','吳':'吴','蘇':'苏','羅':'罗','韓':'韩','馮':'冯','呂':'吕','蕭':'萧','華':'华','豐':'丰','業':'业','產':'产','經':'经','紅':'红','綠':'绿','藍':'蓝','潔':'洁','淨':'净','臟':'脏','腦':'脑','臉':'脸','腳':'脚','書':'书','畫':'画','語':'语','詩':'诗','輕':'轻','遠':'远','邊':'边','過':'过','還':'还','進':'进','運':'运','導':'导','層':'层','屬':'属','眾':'众','兒':'儿','內':'内','兩':'两','準':'准','減':'减','溫':'温','濕':'湿','熱':'热','燈':'灯','煙':'烟','驚':'惊','麗':'丽','齊':'齐','齒':'齿'};
const fold=x=>normalize(x).replace(/[（(【\[][^）)】\]]*[）)】\]]/g,'').replace(/[（(【\[]/g,'');
const toSimp=x=>[...x].map(c=>T2S[c]||c).join('');
const looseName=(a,b)=>{const x=fold(a),y=fold(b);if(!x||!y)return false;if(x===y||x.includes(y)||y.includes(x))return true;const tx=toSimp(x),ty=toSimp(y);return tx===ty||tx.includes(ty)||ty.includes(tx);};
const GD='http://music-api.gdstudio.xyz/api.php';
async function gd(params,tries=4){let last=null;for(let i=0;i<tries;i++){try{const r=await fetch(GD+'?'+new URLSearchParams(params),{headers:{'User-Agent':'Mozilla/5.0'},signal:AbortSignal.timeout(30000)});if(r.ok){const j=await r.json();if(Array.isArray(j)?j.length:j&&j.url)return j;last=j;}}catch{}if(i<tries-1)await new Promise(r=>setTimeout(r,1500));}return last;}
async function alternative(meta,input){
 const name=meta.name||input.name,artist=meta.artist||input.artist;
 if(!name||!artist||!meta.expectedDuration)return null;
 const params=new URLSearchParams({s:name+' '+artist,type:'1',limit:'8'});
 let candidates=[];
 try{
  const d=await json('https://music.163.com/api/search/get?'+params);
  candidates=(d.result?.songs||[]).map(t=>({id:String(t.id),name:t.name,artist:(t.artists||[]).map(a=>a.name).join('/')}));
 }catch{}
 if(!candidates.length){
  try{
   const data=await json('https://api.qijieya.cn/meting/?'+new URLSearchParams({server:'netease',type:'search',id:name+' '+artist,limit:'8',page:'1'}));
   candidates=Array.isArray(data)?data.map(t=>({...t,id:new URL(t.url).searchParams.get('id')})):[];
  }catch{}
 }
 for(const t of candidates){
  if(normalize(t.name)!==normalize(name)||artistSet(t.artist)!==artistSet(artist))continue;
  for(const host of ['https://api.qijieya.cn/meting/','https://api.injahow.cn/meting/']){
   try{return await download({source:'netease',id:t.id,name:t.name,artist:t.artist,url:host+'?'+new URLSearchParams({server:'netease',type:'url',id:t.id}),expectedDuration:meta.expectedDuration,substituted:true});}catch{}
  }
 }
 for(const source of ['tencent','kugou'].filter(s=>s!==meta.source)){
  let rows=[];
  try{
   const data=await json('https://api.qijieya.cn/meting/?'+new URLSearchParams({server:source,type:'search',id:name+' '+artist,limit:'8',page:'1'}));
   rows=Array.isArray(data)?data:[];
  }catch{}
  for(const row of rows){
   if(normalize(row.name)!==normalize(name)||artistSet(row.artist)!==artistSet(artist))continue;
   try{
    const id=row.id||new URL(row.url).searchParams.get('id');
    const candidate=await official(source,id);
    if(candidate.unavailable||normalize(candidate.name)!==normalize(name)||artistSet(candidate.artist)!==artistSet(artist))continue;
    if(Math.abs(candidate.expectedDuration-meta.expectedDuration)>Math.max(4,meta.expectedDuration*.025))continue;
    return await download({...candidate,expectedDuration:meta.expectedDuration,substituted:true});
   }catch{}
  }
 }
 const inTok=artistSet(artist).split('|').filter(Boolean);
 if(inTok.length){
  try{
   const rows=await gd({types:'search',source:'joox',name:name+' '+artist,count:'30',pages:'1'});
   const list=Array.isArray(rows)?rows:[];
   const cand=list.filter(r=>{
    if(!r.id||!looseName(r.name,name))return false;
    const rt=artistSet((r.artist||[]).join('/')).split('|').filter(Boolean);
    if(!inTok.every(t=>rt.includes(t)))return false;
    return !/伴奏|DJ|降調|降调|絕對|绝对|彈唱|弹唱|翻唱|remix|instrumental|0\.8x|阿卓/i.test(String(r.name||''));
   });
   for(const row of cand.slice(0,3)){
    for(const br of ['320','128']){
     const u=await gd({types:'url',source:'joox',id:String(row.id),br});
     if(!u||!u.url)continue;
     try{
      return await download({source:'joox',id:String(row.id),name:row.name,artist:(row.artist||[]).join('/'),album:row.album||'',url:u.url,headers:{'User-Agent':'Mozilla/5.0','Referer':'https://www.joox.com/'},expectedDuration:meta.expectedDuration,durationTolerance:Math.max(10,meta.expectedDuration*.05),verifyTags:{title:name,artist},substituted:true});
     }catch{break;}
    }
   }
  }catch{}
 }
 return null;
}
export async function resolve(input){
 const {source,id}=input,key=source+':'+id;
 if(results.has(key))return results.get(key);
 if(pending.has(key))return pending.get(key);
 const task=(async()=>{
  const meta=await official(source,id);let failure;
  if(!meta.unavailable){for(const url of meta.urls||[meta.url]){try{const value=await download({...meta,url});results.set(key,value);return value;}catch(e){failure=e;}}}
  const alt=await alternative(meta,input).catch(()=>null);
  if(alt){results.set(key,alt);return alt;}
  throw failure||new PlaybackError(meta.reason+'；未找到歌手、曲名和时长一致的免费完整音源','RIGHTS_REQUIRED');
 })();
 pending.set(key,task);try{return await task;}finally{pending.delete(key);}
}
export function getMedia(token){return /^[a-f0-9]{36}$/.test(token)?media.get(token):null;}
