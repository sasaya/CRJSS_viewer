// Juliaが保存した改善解を表示します。探索の時刻と、再生間隔は別の値です。
function mountHoistHistory(root, data) {
  if (root._hoist) { root._hoist.update(data); return; }
  root.innerHTML = `<style>
    .hoist-player { font-family:system-ui,sans-serif;color:#183444;background:#fff;padding:16px;overflow-anchor:none }
    .hoist-player button,.hoist-player select {padding:7px;margin:4px;border:1px solid #9aaeb9;border-radius:5px;background:white;color:#183444}
    .hoist-player button:disabled {opacity:.4} .hoist-player label{display:inline-block;margin:5px}
    .hoist-player .toolbar{display:flex;align-items:center;flex-wrap:wrap;gap:5px}
    .hoist-player .frame-slider {width:min(500px,65vw)}
    .hoist-player .chart{overflow:auto;border:1px solid #dee6eb;min-height:1100px;overflow-anchor:none}
    .hoist-player .chart svg{max-width:none} .hoist-player .progress{width:100%;max-width:1050px}
    .hoist-player table{border-collapse:collapse;font-size:14px;width:100%}
    .hoist-player td,.hoist-player th{padding:7px;border-bottom:1px solid #ddd;text-align:right}
    .hoist-player tr.selected{background:#dcf5ef}.hoist-player tbody tr{cursor:pointer}
    .hoist-player .log{height:260px;overflow:auto}.hoist-player .meta{white-space:pre-wrap;overflow-wrap:anywhere}
  </style><section class="hoist-player">
    <h2>最良解の更新履歴</h2><p class="status"></p>
    <div class="toolbar"><button data-action="previous">◀ 前</button><button data-action="play">▶ 再生</button>
    <button data-action="next">次 ▶</button><button data-action="latest">最新</button>
    <input class="frame-slider" type="range" min="0" max="0" value="0" aria-label="改善解の番号">
    <label>再生間隔 <select class="speed"><option value="2000">2秒</option><option value="1000" selected>1秒</option><option value="500">0.5秒</option><option value="250">0.25秒</option></select></label>
    <label>図 <select class="style"><option value="trajectory">時刻×槽番号</option><option value="gantt">従来のガント図</option></select></label>
    <label><input class="follow" type="checkbox" checked>新しい解を追従</label></div>
    <div class="layers"><label><input type="checkbox" data-layer="job-label" checked>時刻ラベル</label>
    <label><input type="checkbox" data-layer="dwell" checked>槽内処理</label>
    <label><input type="checkbox" data-layer="terminal" checked>終端処理</label>
    <label><input type="checkbox" data-layer="empty" checked>空移動</label>
    <label><input type="checkbox" data-layer="idle" checked>待機</label></div>
    <p class="selection"></p><div class="progress"></div><div class="chart"></div>
    <h3>更新ログ（行またはグラフの点をクリックして選択）</h3><div class="log"><table>
    <thead><tr><th>更新</th><th>探索経過秒</th><th>周期T</th><th>下界</th><th>改善量</th><th>Gap %</th></tr></thead><tbody></tbody></table></div>
    <details><summary>保存先・状態の詳細</summary><p class="meta"></p></details>
  </section>`;
  const q = s=>root.querySelector(s);
  let frames=[],index=0,timer=null,current=data,feed=null,pollTimer=null,polling=false,abort=null;
  const stop=()=>{clearInterval(timer);timer=null;q('[data-action=play]').textContent='▶ 再生';};
  const select=i=>{index=Math.max(0,Math.min(frames.length-1,i));render();};
  const layers=()=>q('.chart').querySelectorAll('[class]').forEach(el=>{
    el.style.display=[...root.querySelectorAll('[data-layer]')].some(b=>!b.checked&&el.classList.contains(b.dataset.layer))?'none':'';
  });
  function progress() {
    if (!frames.length) {q('.progress').innerHTML='';return;}
    const W=1000,H=180,L=65,R=20,top=20,bottom=32;
    const xmax=Math.max(1,...frames.map(f=>f.solver_seconds));
    const ymin=Math.min(...frames.map(f=>Math.min(f.T,f.bound)))-5;
    const ymax=Math.max(...frames.map(f=>f.T))+5;
    const x=t=>L+t/xmax*(W-L-R),y=v=>H-bottom-(v-ymin)/(ymax-ymin)*(H-top-bottom);
    let result=`<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="探索経過秒と最良周期の推移"><rect width="100%" height="100%" fill="#f5f9fb"/>`;
    result+=`<text x="4" y="15" font-size="12">周期T</text><text x="820" y="176" font-size="12">探索経過秒（実時間）</text>`;
    for(let i=0;i<=4;i++){let t=xmax*i/4;result+=`<text x="${x(t)}" y="166" font-size="11">${t.toFixed(2)}</text>`;}
    for(let i=0;i<frames.length;i++){
      const f=frames[i],last=frames[Math.max(0,i-1)];
      if(i)result+=`<path d="M${x(last.solver_seconds)},${y(last.T)} H${x(f.solver_seconds)} V${y(f.T)}" fill="none" stroke="#13826f" stroke-width="2"/>`;
      result+=`<circle data-frame="${i}" cx="${x(f.solver_seconds)}" cy="${y(f.T)}" r="${i===index?7:4}" fill="${i===index?'#e17c24':'#13826f'}" style="cursor:pointer"><title>更新${i+1}: ${f.solver_seconds.toFixed(3)}秒 / T=${f.T}</title></circle>`;
    }
    result+=`<text x="8" y="${y(frames[0].T)+4}" font-size="12">${frames[0].T}</text><text x="8" y="${y(frames[frames.length-1].bound)+4}" font-size="12">${frames[frames.length-1].bound}</text>`;
    result+=`<line x1="${L}" x2="${W-R}" y1="${y(frames[frames.length-1].bound)}" y2="${y(frames[frames.length-1].bound)}" stroke="#8c6979" stroke-dasharray="5 4"/><text x="${L+10}" y="${y(frames[frames.length-1].bound)-5}" font-size="11">最終記録時の下界</text></svg>`;
    q('.progress').innerHTML=result;
    q('.progress').querySelectorAll('[data-frame]').forEach(dot=>dot.onclick=()=>{stop();q('.follow').checked=false;select(+dot.dataset.frame);});
  }
  function render(){
    q('.status').textContent=`状態: ${current.status} / 改善解 ${frames.length} 件`+(current.final?` / 終了時の下界 ${current.final.bound}`:'');
    q('.meta').textContent=current.directory+(current.error?'\n'+current.error:'');
    q('.frame-slider').max=Math.max(0,frames.length-1);q('.frame-slider').value=index;
    root.querySelectorAll('[data-action],.frame-slider').forEach(el=>el.disabled=!frames.length);
    if(!frames.length){q('.selection').textContent='改善解が得られると、ログと図をここに表示します。';q('.chart').innerHTML='';return;}
    const f=frames[index];
    q('.selection').textContent=`更新 ${index+1}/${frames.length}　探索 ${f.solver_seconds.toFixed(3)}秒　T=${f.T}　下界=${f.bound}　Gap=${f.gap_percent.toFixed(2)}%`;
    q('.chart').innerHTML=f[q('.style').value];layers();progress();
    q('tbody').innerHTML=frames.map((f,i)=>`<tr data-index="${i}" class="${i===index?'selected':''}"><td>${i+1}</td><td>${f.solver_seconds.toFixed(3)}</td><td>${f.T}</td><td>${f.bound}</td><td>${f.improvement??'初回'}</td><td>${f.gap_percent.toFixed(2)}</td></tr>`).join('');
    q('tbody').querySelectorAll('tr').forEach(row=>row.onclick=()=>{stop();q('.follow').checked=false;select(+row.dataset.index);});
  }
  q('[data-action=play]').onclick=()=>{
    if(timer){stop();return;} if(index>=frames.length-1)index=0;
    q('.follow').checked=false;render();q('[data-action=play]').textContent='⏸ 一時停止';
    timer=setInterval(()=>{if(index>=frames.length-1){stop();return;}select(index+1);},+q('.speed').value);
  };
  q('.speed').onchange=()=>{if(timer){stop();q('[data-action=play]').click();}};
  q('[data-action=previous]').onclick=()=>{stop();q('.follow').checked=false;select(index-1);};
  q('[data-action=next]').onclick=()=>{stop();q('.follow').checked=false;select(index+1);};
  q('[data-action=latest]').onclick=()=>{stop();q('.follow').checked=true;select(frames.length-1);};
  q('.frame-slider').oninput=e=>{stop();q('.follow').checked=false;select(+e.target.value);};
  q('.style').onchange=render;
  root.querySelectorAll('[data-layer]').forEach(box=>box.onchange=layers);
  async function poll() {
    if(polling||!feed)return;
    polling=true;abort=new AbortController();
    try {
      const state=await(await fetch(feed+'/state',{cache:'no-store',signal:abort.signal})).json();
      const received=[...frames];
      for(let i=received.length;i<state.entries.length;i++){
        const response=await fetch(feed+'/frame/'+(i+1),{cache:'no-store',signal:abort.signal});
        if(!response.ok)throw new Error('図を取得できません: '+response.status);
        received.push(await response.json());
      }
      root._hoist.update({...state,directory:current.directory,frames:received});
      if(['OPTIMAL','INFEASIBLE','FEASIBLE','STOPPED','ERROR','UNKNOWN'].includes(state.status)){
        clearInterval(pollTimer);pollTimer=null;
      }
    }catch(error){
      if(error.name!=='AbortError')q('.status').textContent='表示更新を再試行します: '+error.message;
    }finally{polling=false;}
  }
  root._hoist={stop,
    destroy(){stop();clearInterval(pollTimer);pollTimer=null;abort?.abort();feed=null;},
    startPoll(url){if(feed===url)return;clearInterval(pollTimer);abort?.abort();feed=url;
      pollTimer=setInterval(poll,2000);poll();},
    update(next){const changed=next.frames.length!==frames.length;
    const statusChanged=next.status!==current.status;
    current=next;frames=next.frames;
    if(changed&&q('.follow').checked)index=Math.max(0,frames.length-1);
    if(changed||statusChanged||!q('.status').textContent)render();}};
  root._hoist.update(data);
}
