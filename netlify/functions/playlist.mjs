// Public playlist metadata only. Audio continues through the existing Meting service.
const METING = 'https://api.qijieya.cn/meting/';
const PAGE_SIZE = 100;
async function getJSON(url, referer) {
  const response = await fetch(url, {
    headers: {'User-Agent':'Mozilla/5.0', Referer:referer},
    signal: AbortSignal.timeout(18000)
  });
  if (!response.ok) throw new Error('平台接口 HTTP ' + response.status);
  return response.json();
}
function track(server, song) {
  const id = server === 'netease' ? song.id : (song.mid || song.songmid);
  if (!id) throw new Error('平台返回曲目缺少 ID');
  const link = type => METING + '?' + new URLSearchParams({server,type,id:String(id)});
  const album = song.al || song.album || {};
  const albumMid = album.mid || song.albummid;
  return {id:String(id),name:song.name || song.songname || song.title || '未知曲目',
    artist:(song.ar || song.artists || song.singer || []).map(s=>s.name).join(' / '),
    url:link('url'), lrc:link('lrc'),
    pic:album.picUrl || (albumMid ? 'https://y.gtimg.cn/music/photo_new/T002R300x300M000'+albumMid+'.jpg' : '')};
}
export async function readPage(server, id, offset, get = getJSON) {
  if (server === 'netease') {
    // v6 returns all track IDs even when its embedded tracks array is truncated.
    const body = await get('https://music.163.com/api/v6/playlist/detail?'+new URLSearchParams({id,n:'100000',s:'0'}), 'https://music.163.com/');
    const p = body.playlist;
    if (body.code !== 200 || !p || !Array.isArray(p.trackIds)) throw new Error('网易云歌单不可读取，请检查是否公开');
    const total = Number(p.trackCount ?? p.trackIds.length);
    if (!Number.isSafeInteger(total) || total < 0 || p.trackIds.length !== total) throw new Error('网易云未返回完整曲目 ID，无法确认完整歌单');
    const ids = p.trackIds.slice(offset, offset + PAGE_SIZE).map(t=>String(t.id));
    let songs = p.tracks || [];
    if (ids.some(id=>!songs.some(s=>String(s.id)===id))) {
      const detail = await get('https://music.163.com/api/v3/song/detail?'+new URLSearchParams({c:JSON.stringify(ids.map(id=>({id}))),ids:JSON.stringify(ids)}), 'https://music.163.com/');
      if (detail.code !== 200 || !Array.isArray(detail.songs)) throw new Error('网易云曲目信息读取失败');
      songs = detail.songs;
    }
    const byId = new Map(songs.map(s=>[String(s.id),s]));
    const items = ids.map(id=>byId.has(id) ? track(server,byId.get(id)) : {
      id,name:'暂不可用曲目 '+id,artist:'平台未返回曲目信息',
      url:METING+'?'+new URLSearchParams({server,type:'url',id}),
      lrc:METING+'?'+new URLSearchParams({server,type:'lrc',id}),pic:''
    });
    return {title:p.name||id,total,items,nextOffset:offset+ids.length,complete:offset+ids.length>=total};
  }
  const query = {comm:{ct:24,cv:0},req_0:{module:'music.srfDissInfo.aiDissInfo',method:'uniform_get_Dissinfo',param:{disstid:Number(id),song_begin:offset,song_num:PAGE_SIZE,onlysonglist:1}}};
  const body = await get('https://u.y.qq.com/cgi-bin/musicu.fcg?'+new URLSearchParams({data:JSON.stringify(query)}), 'https://y.qq.com/');
  const req=body.req_0, data=req?.data;
  if (body.code!==0 || req?.code!==0 || !data || data.code!==0 || !Array.isArray(data.songlist)) throw new Error('QQ 歌单不可读取，请检查是否公开');
  const total=Number(data.dirinfo?.songnum ?? data.total_song_num);
  if (!Number.isSafeInteger(total)||total<0) throw new Error('QQ 未返回歌单总数，无法确认完整歌单');
  const items=data.songlist.map(s=>track(server,s));
  return {title:data.dirinfo?.title||id,total,items,nextOffset:offset+items.length,complete:offset+items.length>=total};
}
export async function handler(event) {
  const q=event.queryStringParameters||{}, server=q.server, id=q.id||'', offset=Number(q.offset||0);
  const headers={'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store'};
  if (!['netease','tencent'].includes(server)||!/^\d{1,16}$/.test(id)||!Number.isSafeInteger(Number(id))||!Number.isSafeInteger(offset)||offset<0) return {statusCode:400,headers,body:JSON.stringify({error:'无效的歌单参数'})};
  try {return {statusCode:200,headers,body:JSON.stringify(await readPage(server,id,offset))};}
  catch(e) {return {statusCode:502,headers,body:JSON.stringify({error:e.message})};}
}
