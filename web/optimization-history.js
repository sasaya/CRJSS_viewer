'use strict';
// The diagrams use the Notebook's verified Julia SVG exporters; only the
// selected frame is fetched, independently of the 200 ms simulation polling.
let optimizationHistory=null,historyPolling=false,historyFrame=null,historyGeneration=0,historyTimer=null,historyIdentity='',historyAutoRequest=true;
function rememberOptimizationView(){viewPreference.optimization={request:$('history-request').value,index:Number($('history-index').value),style:$('history-style').value,follow:$('history-follow').checked,autoRequest:historyAutoRequest};saveView();}
function stopHistoryPlayback(){clearInterval(historyTimer);historyTimer=null;$('history-play').textContent='▶ 再生';}
function applyHistoryLayers(){for(const [id,layer] of [['history-labels','job-label'],['history-dwell','dwell'],['history-terminal','terminal'],['history-empty','empty'],['history-idle','idle']])$('history-diagram').querySelectorAll('.'+layer).forEach(el=>el.style.display=$(id).checked?'':'none');}
function finalHistoryGap(state){const final=state?.final;if(!final)return null;if(final.gap_percent!=null)return final.gap_percent;const T=final.T??state.entries?.at(-1)?.T;return T!=null&&final.bound!=null?Math.max(0,100*(T-final.bound)/Math.max(1,Math.abs(T))):null;}
function historySelectionText(entry,index,state){return `更新 ${index}/${state.entries.length} / 探索 ${fmt(entry.solver_seconds)}秒 / 周期T ${entry.T}秒 / 取得時の下界 ${fmt(entry.bound)}秒 / 取得時ギャップ ${gapText(entry.gap_percent)}%`+(index===state.entries.length&&finalHistoryGap(state)!=null?` / 最終下界 ${fmt(state.final.bound)}秒 / 最終ギャップ ${gapText(finalHistoryGap(state))}%`:'');}
function renderConvergence(){
 const entries=optimizationHistory?.entries||[];if(!entries.length){$('history-convergence').innerHTML='まだ改善解がありません。';$('history-log').innerHTML='';return;}
 const W=Math.max(480,Math.floor($('history-convergence').getBoundingClientRect().width)),H=235,L=70,R=25,top=28,bottom=45;
 const final=optimizationHistory.final,progress=final?null:optimizationHistory.progress,xmax=Math.max(1,...entries.map(e=>e.solver_seconds),final?.solver_seconds||0,progress?.solver_seconds||0);
 const all=entries.flatMap(e=>[e.T,e.bound]).concat(final?.bound!=null?[final.bound]:[],progress?.bound!=null?[progress.bound]:[]),lo=Math.min(...all)-2,hi=Math.max(...all)+2;
 const x=t=>L+t/xmax*(W-L-R),y=v=>H-bottom-(v-lo)/(hi-lo)*(H-top-bottom),index=Number($('history-index').value);
 let svg=`<svg width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" role="img" aria-label="周期Tと下界の収束過程"><rect width="100%" height="100%" fill="#0b1120"/><text x="6" y="16" font-size="12" fill="#edf3fc">周期T（秒）</text>`;
 for(let i=0;i<=4;i++){const t=xmax*i/4,v=lo+(hi-lo)*i/4;svg+=`<line x1="${L}" y1="${y(v)}" x2="${W-R}" y2="${y(v)}" stroke="#2c3b53"/><text x="${L-8}" y="${y(v)+4}" text-anchor="end" font-size="12" fill="#aab8cd">${fmt(v)}</text><text x="${x(t)}" y="${H-25}" text-anchor="middle" font-size="12" fill="#aab8cd">${fmt(t)}</text>`;}
 const step=field=>entries.map((e,i)=>i?`H${x(e.solver_seconds)} V${y(e[field])}`:`M${x(e.solver_seconds)} ${y(e[field])}`).join(' ');
 svg+=`<path d="${step('T')} H${x(xmax)}" fill="none" stroke="#6de0cf" stroke-width="2"/><path d="${step('bound')}" fill="none" stroke="#f4cc75" stroke-width="2" stroke-dasharray="5 4"/>`;
 if(final?.bound!=null)svg+=`<path d="M${x(entries.at(-1).solver_seconds)} ${y(entries.at(-1).bound)} H${x(xmax)} V${y(final.bound)}" fill="none" stroke="#f4cc75" stroke-dasharray="5 4"/><circle data-kind="final-gap" cx="${x(xmax)}" cy="${y(final.T??entries.at(-1).T)}" r="4" fill="#6de0cf"><title>最終下界 ${fmt(final.bound)}秒 / 最終ギャップ ${gapText(finalHistoryGap(optimizationHistory))}%</title></circle>`;
 if(progress?.bound!=null)svg+=`<path data-kind="live-bound" d="M${x(entries.at(-1).solver_seconds)} ${y(entries.at(-1).bound)} H${x(xmax)} V${y(progress.bound)}" fill="none" stroke="#f4cc75" stroke-dasharray="5 4"/><circle cx="${x(xmax)}" cy="${y(progress.bound)}" r="4" fill="#f4cc75"><title>探索中の現在下界 ${fmt(progress.bound)}秒</title></circle>`;
 for(const e of entries)svg+=`<circle data-history-index="${e.index}" cx="${x(e.solver_seconds)}" cy="${y(e.T)}" r="${e.index===index?6:4}" fill="${e.index===index?'#ffb9ef':'#6de0cf'}" style="cursor:pointer"><title>更新${e.index} / ${fmt(e.solver_seconds)}秒 / T=${e.T} / 下界=${e.bound} / Gap=${fmt(e.gap_percent)}%</title></circle>`;
 svg+=`<text x="${L}" y="${H-7}" font-size="12" fill="#6de0cf">実線：最良周期T</text><text x="${L+150}" y="${H-7}" font-size="12" fill="#f4cc75">破線：下界</text><text x="${W-R}" y="${H-7}" text-anchor="end" font-size="12" fill="#aab8cd">探索経過秒</text></svg>`;
 $('history-convergence').innerHTML=svg;
 $('history-convergence').querySelectorAll('[data-history-index]').forEach(el=>el.onclick=()=>{stopHistoryPlayback();$('history-follow').checked=false;void selectOptimizationFrame(Number(el.dataset.historyIndex));});
 $('history-log').innerHTML=entries.map(e=>`<tr data-history-index="${e.index}"><td>${e.index}</td><td>${fmt(e.solver_seconds)}</td><td>${e.T}</td><td>${fmt(e.bound)}</td><td>${e.improvement??'初回'}</td><td>${fmt(e.gap_percent)}</td></tr>`).join('');
 if(finalHistoryGap(optimizationHistory)!=null)$('history-log').innerHTML+=`<tr data-kind="final-gap"><td>最終</td><td>${fmt(final.solver_seconds)}</td><td>${final.T??entries.at(-1).T}</td><td>${fmt(final.bound)}</td><td>—</td><td>${gapText(finalHistoryGap(optimizationHistory))}</td></tr>`;
 $('history-log').querySelectorAll('[data-history-index]').forEach(el=>el.onclick=()=>{stopHistoryPlayback();$('history-follow').checked=false;void selectOptimizationFrame(Number(el.dataset.historyIndex));});
}
async function selectOptimizationFrame(index){
 const state=optimizationHistory;if(!state?.entries?.length){$('history-index').disabled=true;return;}
 index=Math.max(1,Math.min(state.entries.length,index));$('history-index').value=index;$('history-index').disabled=false;renderConvergence();rememberOptimizationView();
 const entry=state.entries[index-1],key=historyIdentity+':'+state.request_id+':'+index,generation=++historyGeneration;
 $('history-selection').textContent=historySelectionText(entry,index,state);
 try{
  if(historyFrame?.key!==key){$('history-selection').textContent+=' / 図を読み込み中…';const frame=await api('/api/optimizer/frame?request='+encodeURIComponent(state.request_id)+'&index='+index);if(generation!==historyGeneration)return;historyFrame={key,...frame};}
  if(generation!==historyGeneration)return;
  $('history-diagram').innerHTML=historyFrame[$('history-style').value]||'図がありません。';applyHistoryLayers();
  $('history-selection').textContent=historySelectionText(entry,index,state);
 }catch(e){if(generation===historyGeneration)$('history-selection').textContent+=' / '+e.message;}
}
async function refreshOptimizationHistory(){
 if(!sessionReady||historyPolling)return;historyPolling=true;
 try{
  const requests=optimizerHistory?.requests||[],current=optimizerHistory?.active?.request_id||requests.at(-1)?.request_id;
  const experiment=latest?.experiment_directory||'';
  if(historyIdentity!==experiment){historyIdentity=experiment;optimizationHistory=null;historyFrame=null;historyGeneration++;stopHistoryPlayback();$('history-convergence').innerHTML='';$('history-diagram').innerHTML='実行可能解を待っています。';$('history-log').innerHTML='';$('history-selection').textContent='';$('history-request').innerHTML='';delete $('history-request').dataset.signature;const saved=viewPreference.optimization||{};historyAutoRequest=saved.autoRequest!==false;$('history-request').value=saved.request||'';$('history-style').value=saved.style||'trajectory';$('history-follow').checked=saved.follow!==false;$('history-index').value=saved.index||1;}
  const selected=$('history-request').value,signature=requests.map(r=>r.request_id+':'+r.status).join('|');
  if($('history-request').dataset.signature!==signature){$('history-request').innerHTML=requests.map(r=>`<option value="${esc(r.request_id)}">${esc(r.request_id)} / ${esc(solverNames[r.optimizer?.solver]||'')} / ${esc(solverStatusNames[r.status]||r.status)}</option>`).join('');$('history-request').dataset.signature=signature;}
  const id=!historyAutoRequest&&requests.some(r=>r.request_id===selected)?selected:current;
  if(!id){$('history-status').textContent='計算が始まると収束過程を表示します。';return;}$('history-request').value=id;
  const data=await api('/api/optimizer/history?request='+encodeURIComponent(id));
  if(experiment!==(latest?.experiment_directory||'')||id!==$('history-request').value)return;
  const changed=optimizationHistory?.request_id!==id,previousLength=optimizationHistory?.entries?.length||0;
  optimizationHistory=data;const entries=data.entries||[];
  $('history-status').textContent=`${id} / ${solverStatusNames[data.status]||({starting:'準備中',computing:'計算中'}[data.status])||data.status} / 改善解 ${entries.length}件 / 終了条件 ${stopConditionLabel(data.stop_condition,data.gap_percent,data.solver_limit_wall_seconds??'—')}`+(data.error?' / '+data.error:'');
  if(finalHistoryGap(data)!=null)$('history-status').textContent+=` / 最終ギャップ ${gapText(finalHistoryGap(data))}%`;
  else if(data.progress?.gap_percent!=null)$('history-status').textContent+=` / 現在下界 ${fmt(data.progress.bound)}秒 / 現在ギャップ ${gapText(data.progress.gap_percent)}%`;
  $('history-index').max=Math.max(1,entries.length);$('history-play').disabled=!entries.length;
  if(!entries.length){$('history-index').disabled=true;$('history-diagram').innerHTML='実行可能解を待っています。';historyFrame=null;renderConvergence();return;}
  const index=$('history-follow').checked?entries.length:Number($('history-index').value)||1;
  if(changed||entries.length!==previousLength||!historyFrame)await selectOptimizationFrame(index);else{renderConvergence();$('history-selection').textContent=historySelectionText(entries[Math.min(entries.length,index)-1],Math.min(entries.length,index),data);}
 }catch(e){$('history-status').textContent=e.status===404?'この表示を有効にするにはサーバーを再起動してください。':'収束過程への再接続中… '+e.message;}
 finally{historyPolling=false;}
}
$('history-request').onchange=()=>{stopHistoryPlayback();historyAutoRequest=false;optimizationHistory=null;historyFrame=null;rememberOptimizationView();void refreshOptimizationHistory();};
$('history-index').oninput=()=>{stopHistoryPlayback();$('history-follow').checked=false;void selectOptimizationFrame(Number($('history-index').value));};
$('history-style').onchange=()=>void selectOptimizationFrame(Number($('history-index').value));
$('history-follow').onchange=()=>{rememberOptimizationView();if($('history-follow').checked)void selectOptimizationFrame(optimizationHistory?.entries?.length||1);};
$('history-latest').onclick=()=>{stopHistoryPlayback();historyAutoRequest=true;$('history-follow').checked=true;$('history-request').value='';historyFrame=null;void refreshOptimizationHistory();};
for(const id of ['history-labels','history-dwell','history-terminal','history-empty','history-idle'])$(id).onchange=applyHistoryLayers;
$('history-play').onclick=()=>{if(historyTimer!==null){stopHistoryPlayback();return;}$('history-follow').checked=false;if(Number($('history-index').value)>=optimizationHistory?.entries?.length)void selectOptimizationFrame(1);$('history-play').textContent='⏸ 一時停止';historyTimer=setInterval(()=>{const index=Number($('history-index').value);if(index>=optimizationHistory.entries.length){stopHistoryPlayback();return;}void selectOptimizationFrame(index+1);},Number($('history-speed').value));};
if(sessionReady)void refreshOptimizationHistory();
