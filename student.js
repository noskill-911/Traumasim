(function(){'use strict';
const qs=new URLSearchParams(location.search),caseId=qs.get('case')||'vu-baum',patientId=qs.get('patient')||'fahrer';
const scenario=window.TRAUMA_CASES.find(x=>x.id===caseId),patient=scenario&&scenario.patients.find(x=>x.id===patientId);
const el=id=>document.getElementById(id);
if(!patient){el('content').innerHTML='<div class="panel"><h1>Patient nicht gefunden</h1><a href="index.html">Zur Übersicht</a></div>';return}
el('caseTitle').textContent=scenario.title;el('patientTitle').textContent=patient.name;el('intro').textContent=patient.intro;el('story').textContent=patient.story;el('questions').textContent=patient.questions;
let elapsed=0,previous=performance.now();const started=performance.now();
function interpolate(sec){let m=Math.max(0,Math.min(sec/60,25)),i=Math.min(4,Math.floor(m/5)),a=patient.points[i],b=patient.points[i+1],f=(m-a.t)/5,v={};for(let k of ['s','d','h','r','o','g'])v[k]=Math.round(a[k]+(b[k]-a[k])*f);return v}
function classification(v){if(patient.id==='beifahrer')return {name:'SK II · GELB',css:'yellow',why:'Schwer verletzt, zunächst ohne erkennbare vitale Bedrohung'};if(v.s<100||v.g<15||v.h>=120)return{name:'SK I · ROT',css:'red',why:'Didaktische Einstufung: Zeichen eines kritischen Schocks'};return{name:'SK II · GELB',css:'yellow',why:'Schwere Verletzung, Kreislauf zunächst kompensiert'}}
function condition(v){if(patient.id==='beifahrer')return patient.condition[Math.min(3,Math.floor(elapsed/420))];if(v.g<=12)return patient.condition[3];if(v.s<100)return patient.condition[2];if(v.h>=110)return patient.condition[1];return patient.condition[0]}
function render(){let v=interpolate(elapsed),tr=classification(v);el('triagePanel').classList.toggle('hidden',elapsed<60);el('vitalsPanel').classList.toggle('hidden',elapsed<120);el('triageBox').className='triage '+tr.css;el('triage').textContent=tr.name;el('triageReason').textContent=tr.why;el('patientCondition').textContent=condition(v);el('bp').textContent=v.s+'/'+v.d;el('hr').textContent=v.h;el('rr').textContent=v.r;el('spo').textContent=v.o;el('gcs').textContent=v.g;el('elapsed').textContent=String(Math.floor(elapsed/60)).padStart(2,'0')+':'+String(Math.floor(elapsed%60)).padStart(2,'0')}
function tick(now){elapsed=Math.min(1500,elapsed+Math.max(0,(now-previous)/1000));previous=now;render();if(elapsed<1500)requestAnimationFrame(tick)}
render();requestAnimationFrame(tick);
})();