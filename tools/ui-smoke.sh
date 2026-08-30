#!/usr/bin/env bash
# Browser smoke gate for the deployed or local FlowRat shell.
set -euo pipefail
url="${FLOWRAT_URL:-http://127.0.0.1:8731/?ui-smoke=1}"
FLOWRAT_URL="$url" ego-browser nodejs <<'EOF'
const target = 'http://127.0.0.1:8731/?ui-smoke=1';
const task = await useOrCreateTaskSpace('flowrat ui smoke ' + target);
await openOrReuseTab(target, {wait:true, timeout:30});
await gotoAndWait(target, {timeout:30, settle:1});
const fail = (m) => { throw new Error(m); };
const summary = await js(`(() => {
  const ids=['canvas','canvas3d','run','step','reset','fullscreen','experiment','run-experiment','download-trajectory','app-state','state-dot','experiment-description','setup3d','setup3d-note'];
  const missing=ids.filter(id=>!document.getElementById(id));
  const s=document.querySelector('.stage'), r=s&&s.getBoundingClientRect();
  const ratio=r ? r.width/r.height : 0;
  return {missing, options:document.querySelectorAll('#experiment option').length,
    ratio, width:r&&r.width, height:r&&r.height, scrollHeight:document.documentElement.scrollHeight,
    viewport:[innerWidth,innerHeight]};
})()`);
if (summary.missing.length) fail('missing controls: '+summary.missing.join(','));
if (summary.options !== 9) fail('expected 9 experiment presets, found '+summary.options);
const setups = await js(`document.querySelectorAll('#setup3d option').length`);
if (setups !== 4) fail('expected 4 3D setups, found '+setups);
await js(`document.querySelector('#setup3d').value='maze'; document.querySelector('#setup3d').dispatchEvent(new Event('change',{bubbles:true}))`);
const setupNote = await js(`document.querySelector('#setup3d-note').textContent`);
if (!String(setupNote).includes('maze')) fail('3D setup did not update description: '+setupNote);
if (Math.abs(summary.ratio-1.6) > .03) fail('stage aspect ratio is '+summary.ratio);
const initialDescription = await js(`document.querySelector('#experiment-description').textContent`);
if (!initialDescription || initialDescription.length < 20) fail('experiment description is missing');
await js(`document.querySelector('#run-experiment').click()`);
await wait(4);
let state = await js(`document.querySelector('#status').textContent`);
if (!String(state).includes('running')) fail('experiment did not start: '+state);
await js(`document.querySelector('#run').click()`); await wait(.3);
state=await js(`document.querySelector('#status').textContent`);
if (!String(state).includes('paused')) fail('pause did not update status: '+state);
await js(`document.querySelector('#run').click()`); await wait(.3);
await js(`document.querySelector('#step').click(); document.querySelector('#reset').click()`);
for (const value of [...Array(9)].map((_,i)=>String(i+1))) {
  await js(`(() => { const e=document.querySelector('#experiment'); e.value='${value}'; e.dispatchEvent(new Event('change',{bubbles:true})); })()`);
  await js(`document.querySelector('#run-experiment').click()`);
  await wait(1);
  state = await js(`document.querySelector('#status').textContent`);
  if (String(state).includes('failed') || String(state).includes('idle')) fail('preset ${value} failed: '+state);
}
const end = await js(`(() => { const c=document.querySelector('canvas'), r=document.querySelector('.stage').getBoundingClientRect(); return {cw:c.width,ch:c.height,sw:r.width,sh:r.height,errors:document.querySelector('#out').innerText.includes('Error')}; })()`);
if (end.cw<=0 || end.ch<=0 || end.errors) fail('canvas/runtime invariant failed: '+JSON.stringify(end));
cliLog(JSON.stringify({ok:true,task:task.id,summary,end}));
EOF
