import http from 'node:http';
import {readFile,stat} from 'node:fs/promises';
import {createReadStream} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {resolve,getMedia,PlaybackError} from './playback.mjs';
const page=fileURLToPath(new URL('./index.html',import.meta.url));
const port=Number(process.env.PORT||18772);
function send(res,status,data){res.writeHead(status,{'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});res.end(JSON.stringify(data));}
const server=http.createServer(async(req,res)=>{
 try{
  if(!['GET','HEAD'].includes(req.method))return send(res,405,{error:'Method not allowed'});
  const url=new URL(req.url,'http://127.0.0.1:'+port);
  if(url.pathname==='/'||url.pathname==='/index.html'){
   const body=await readFile(page);res.writeHead(200,{'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store','Content-Length':body.length});return res.end(req.method==='HEAD'?undefined:body);
  }
  if(url.pathname==='/api/health')return send(res,200,{ready:true,mode:'verified-full-audio',sources:['netease','tencent','kugou','joox','kuwo'],checks:['duration','audio-codec','full-decode','tail-decode']});
  if(url.pathname==='/.netlify/functions/playback'){
   const origin=req.headers.origin;
   if(origin){let oh='';try{oh=new URL(origin).host}catch{}
    if(oh&&oh!==(req.headers.host||''))return send(res,403,{error:'Origin not allowed'});}
   const result=await resolve({source:url.searchParams.get('source'),id:url.searchParams.get('id'),name:(url.searchParams.get('name')||'').slice(0,160),artist:(url.searchParams.get('artist')||'').slice(0,160)});
   return send(res,200,result);
  }
  if(url.pathname.startsWith('/media/')){
   const item=getMedia(url.pathname.slice(7));if(!item)return send(res,404,{error:'音频缓存已失效，请重新选择歌曲'});
   let start=0,end=item.size-1,partial=false;
   if(req.headers.range){
    const match=/^bytes=(\d*)-(\d*)$/.exec(req.headers.range);
    if(!match||(!match[1]&&!match[2]))return send(res,416,{error:'Invalid Range'});
    if(!match[1])start=Math.max(0,item.size-Number(match[2]));
    else{start=Number(match[1]);if(match[2])end=Math.min(Number(match[2]),end);}
    if(!Number.isSafeInteger(start)||!Number.isSafeInteger(end)||start<0||start> end||start>=item.size){res.writeHead(416,{'Content-Range':'bytes */'+item.size});return res.end();}partial=true;
   }
   const h={'Content-Type':item.mime,'Content-Length':end-start+1,'Accept-Ranges':'bytes','Cache-Control':'private, max-age=600','X-Content-Type-Options':'nosniff'};
   if(partial)h['Content-Range']=`bytes ${start}-${end}/${item.size}`;
   res.writeHead(partial?206:200,h);if(req.method==='HEAD')return res.end();
   const stream=createReadStream(item.file,{start,end});stream.on('error',()=>res.destroy());res.on('close',()=>stream.destroy());return stream.pipe(res);
  }
  if(url.pathname==='/.netlify/functions/playlist'){
   const p=url.searchParams;
   if(!['netease','tencent'].includes(p.get('server'))||!/^\d{1,16}$/.test(p.get('id')||'')||!/^\d{1,7}$/.test(p.get('offset')||'0'))return send(res,400,{error:'无效的歌单参数'});
   const r=await fetch('https://peaceful-horse-1c53e3.netlify.app/.netlify/functions/playlist?'+p,{signal:AbortSignal.timeout(25000)});
   res.writeHead(r.status,{'Content-Type':'application/json','Cache-Control':'no-store'});return res.end(await r.text());
  }
  return send(res,404,{error:'Not found'});
 }catch(e){if(res.headersSent)return res.destroy();send(res,e instanceof PlaybackError?(e.code==='PARAM'?400:422):502,{error:e.message,code:e.code||'UPSTREAM'});}
});
server.listen(port,process.env.HOST||'0.0.0.0',()=>console.log('音乐雷达完整播放：http://'+(process.env.HOST||'0.0.0.0')+':'+port));
