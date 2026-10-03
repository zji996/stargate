'use strict';
const $ = s => document.querySelector(s);
const escapeHTML = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const paths = {
  overview:'M3 3h7v7H3z M14 3h7v7h-7z M3 14h7v7H3z M14 14h7v7h-7z',
  nodes:'M12 3v6 M5 21v-5h14v5 M12 16v-3 M9 9h6v4H9z M2 21h6 M16 21h6',
  rules:'M4 6h16 M4 12h16 M4 18h16 M8 3v6 M16 9v6 M10 15v6',
  remote:'M3 4h18v12H3z M8 21h8 M12 16v5 M8 10h8 M13 7l3 3-3 3',
  connections:'M4 16l4-7 4 4 4-9 4 5 M3 21h18',
  diagnostics:'M12 3l8 4v5c0 5-8 9-8 9s-8-4-8-9V7z M8 12l3 3 5-6',
  settings:'M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8 M12 2v3 M12 19v3 M2 12h3 M19 12h3 M5 5l2 2 M17 17l2 2 M5 19l2-2 M17 7l2-2',
  power:'M12 2v10 M6 5a9 9 0 1 0 12 0',
  arrow:'M5 12h14 M13 6l6 6-6 6',
  plus:'M12 4v16 M4 12h16',
  check:'M5 12l4 4L19 6',
  refresh:'M20 7v5h-5 M4 17v-5h5 M6 6a8 8 0 0 1 14 6 M18 18a8 8 0 0 1-14-6',
  download:'M12 3v12 M7 10l5 5 5-5 M4 17v4h16v-4',
  lock:'M7 10V7a5 5 0 0 1 10 0v3 M5 10h14v11H5z M12 14v3',
};
const icon = name => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${paths[name] || paths.overview}"/></svg>`;
const navigation = [['overview','概览'],['nodes','节点'],['rules','分流规则'],['remote','远程访问'],['connections','连接'],['diagnostics','诊断'],['settings','设置']];
const state = {
  connected:true, system:true, mode:'rules', remote:true, remoteTab:'bindings', selected:'west', theme:'light', autostart:false,
  nodes:[{id:'west',name:'美国 · 西海岸',group:'日常上网',region:'US',host:'us-west.example.com',latency:128},{id:'tokyo',name:'日本 · 东京',group:'备用节点',region:'JP',host:'tokyo.example.com',latency:76},{id:'relay',name:'家庭中转',group:'个人节点',region:'US',host:'relay.example.com',latency:146}],
  rules:[{domain:'home.arpa',action:'direct',kind:'内网域名'},{domain:'example.cn',action:'direct',kind:'用户规则'},{domain:'example.org',action:'proxy',kind:'用户规则'}],
  bindings:[{id:'windows',name:'家里的 Windows',service:'home/desktop',port:13389,enabled:true}],
  checks:false, connectionQuery:'', nodeQuery:'', logs:[['14:32:08','INFO','代理配置校验通过'],['14:32:08','INFO','本地 HTTP / SOCKS 入口已就绪'],['14:32:09','INFO','系统代理设置已应用'],['14:32:10','INFO','远程访问固定通道已连接']],
};
const modes={rules:'规则分流',global:'全局代理',direct:'仅直连'};
const actionNames={direct:'直连',proxy:'代理',reject:'拒绝'};
const currentNode=()=>state.nodes.find(n=>n.id===state.selected);
const pill=(text,type='')=>`<span class="pill ${type}">${escapeHTML(text)}</span>`;
const toggle=(action,on,label)=>`<button class="switch" role="switch" aria-checked="${on}" aria-label="${escapeHTML(label)}" data-action="${action}"></button>`;
const button=(text,action,primary=false,ico='')=>`<button type="button" class="button ${primary?'primary':''}" data-action="${action}">${ico?icon(ico):''}${text}</button>`;
const sparkline=(shape='3,21 12,18 20,20 29,10 38,14 46,7 55,12 64,4 74,8')=>`<svg class="sparkline" viewBox="0 0 78 26" aria-hidden="true"><polyline points="${shape}" fill="none" stroke="currentColor" stroke-width="1.7"/></svg>`;
const heading=(title,subtitle,actions='')=>`<div class="page-heading"><div><h1>${title}</h1><p class="subtitle">${subtitle}</p></div>${actions}</div>`;
const card=(title,body,right='')=>`<section class="card"><div class="card-heading"><h2>${title}</h2>${right}</div>${body}</section>`;
const row=(title,subtitle,right)=>`<div class="row"><div class="row-title">${title}${subtitle?`<small>${subtitle}</small>`:''}</div>${right}</div>`;
const remoteStatus=()=>state.remote?'通道已连接':'通道已停止';
function overview(){
 const n=currentNode();
 return heading('让连接，简单一点。','日常上网与远程访问，各自稳定运行。')+
 `<section class="card hero"><div class="connection-orb ${state.connected?'':'off'}"><button class="power" data-action="connect" aria-label="${state.connected?'停止':'启动'}上网代理">${icon('power')}</button></div><div class="hero-copy">${pill(state.connected?'代理已启动':'代理已停止',state.connected?'blue':'neutral')}<h2>${state.connected?escapeHTML(n.name):'准备好，再出发'}</h2><p>${state.connected?`${modes[state.mode]} · ${state.system?'系统代理已开启':'仅本地代理'}`:'启动本地代理后，可按需开启系统代理'}</p><a href="#nodes" class="hint">切换节点 →</a></div><div class="hero-side"><div><div class="latency">${state.connected?n.latency:'—'} <small>ms</small></div><div class="hint">示例连接延迟</div></div>${button(state.connected?'断开连接':'连接代理','connect',!state.connected)}</div></section>`+
 `<div class="stats"><section class="card stat"><div class="stat-top">下载速率 ${sparkline()}</div><div class="stat-number">${state.connected?'2.48':'0'} <small>MB/s</small></div><span class="hint">本次下载 ${state.connected?'386.2':'0'} MB</span></section><section class="card stat"><div class="stat-top">上传速率 ${sparkline('3,20 12,17 20,19 29,15 38,18 46,12 55,17 64,13 74,15')}</div><div class="stat-number">${state.connected?'128':'0'} <small>KB/s</small></div><span class="hint">本次上传 ${state.connected?'24.8':'0'} MB</span></section><section class="card stat"><div class="stat-top">活动连接 ${icon('connections')}</div><div class="stat-number">${state.connected?'12':'0'} <small>个连接</small></div><span class="hint">连接记录仅统计代理内流量</span></section></div>`+
 `<div class="columns">${card('上网方式',row('系统代理','让遵循系统代理的应用使用 Stargate',toggle('system',state.system,'开启系统代理'))+row('代理模式','在代理内部决定流量走向','')+`<div class="segment" aria-label="代理模式">${Object.entries(modes).map(([id,name])=>`<button data-mode="${id}" aria-pressed="${state.mode===id}" class="${state.mode===id?'selected':''}">${name}</button>`).join('')}</div><p class="note">${state.mode==='rules'?'内网与国内站点优先直连，其他流量按规则选择出口。':state.mode==='global'?'普通公网 TCP 流量使用所选节点，保留内网直连。':'进入本地代理的流量直接连接目标。'}</p>`)}${card('远程访问',`<div class="remote-tile"><div class="tile-icon">${icon('remote')}</div><div class="remote-info"><h3>家里的 Windows</h3><p class="code">127.0.0.1:13389</p></div>${pill(state.remote?'可访问':'已停止',state.remote?'':'neutral')}</div><div class="channel-summary">${icon('lock')}固定通道 · 家庭中转 · 独立于当前上网节点</div><div class="row"><span class="hint">${remoteStatus()} · 示例状态</span><a href="#remote" class="hint">管理入口 →</a></div>`)}</div>`+
 card('连接检查',`<div class="metric-grid"><div><span class="hint">节点握手</span><strong>${state.connected?'成功':'未运行'}</strong></div><div><span class="hint">代理出口</span><strong>${state.connected?'可达':'待连接'}</strong></div><div><span class="hint">系统代理</span><strong>${state.system?'已开启':'已关闭'}</strong></div></div>`,button('重新检查','check-overview',false,'refresh'))+
 `<div class="quick-links"><a href="#rules">${icon('rules')}查看分流规则</a><a href="#diagnostics">${icon('diagnostics')}遇到问题？运行诊断</a></div>`;
}
function nodes(){return heading('节点','管理上网出口。远程访问始终使用它自己的固定通道。',button('导入节点','import',true,'plus'))+
 `<div class="search"><input type="text" id="node-search" aria-label="搜索节点" placeholder="搜索名称、地址或分组" value="${escapeHTML(state.nodeQuery)}">${button('检测延迟','latency',false,'refresh')}</div>`+
 card('我的节点',`<div class="table-wrap"><table><thead><tr><th>节点</th><th>协议</th><th>延迟</th><th>状态</th><th>操作</th></tr></thead><tbody id="node-rows">${nodeRows()}</tbody></table></div>`, `<span class="hint">${state.nodes.length} 个节点</span>`)+
 `<div class="banner">导入 anytls:// 只添加上网节点；导入 stargate:// 可开通远程访问，并选择是否同时添加代理节点。</div>`+
 card('订阅与更新',row('个人节点','当前使用手动导入，不会自动更换所选节点',pill('手动维护','neutral'))+`<p class="note">订阅管理预留为后续功能：更新先展示差异，节点失效时保留可恢复的旧配置。</p>`);
}
function nodeRows(){const query=state.nodeQuery.toLowerCase(); const rows=state.nodes.filter(n=>[n.name,n.host,n.group].join(' ').toLowerCase().includes(query));return rows.length?rows.map(n=>`<tr><td><div class="node-title"><span class="region">${escapeHTML(n.region)}</span><div>${escapeHTML(n.name)}<small>${escapeHTML(n.host)} · ${escapeHTML(n.group)}</small></div></div></td><td>${pill('AnyTLS','neutral')}</td><td>${n.latency} <span class="hint">ms</span></td><td>${n.id===state.selected?pill('当前节点','blue'):pill('可用','neutral')}</td><td><div class="table-actions">${n.id===state.selected?'<span class="hint">已选择</span>':button('使用',`select:${n.id}`)}${button('详情',`node:${n.id}`)}</div></td></tr>`).join(''):'<tr><td colspan="5" class="empty">没有符合条件的节点</td></tr>';}
function rules(){return heading('分流规则','把常用策略放在前面，让每次连接都有明确的出口。',button('添加规则','add-rule',true,'plus'))+
 card('当前模式',`<div class="segment">${Object.entries(modes).map(([id,name])=>`<button data-mode="${id}" aria-pressed="${state.mode===id}" class="${state.mode===id?'selected':''}">${name}</button>`).join('')}</div><p class="note">用户规则仅在「规则分流」模式下生效；切换模式会保留已保存规则。</p>`)+
 card('用户规则',`<div class="table-wrap"><table><thead><tr><th>域名 / 后缀</th><th>来源</th><th>策略</th><th>操作</th></tr></thead><tbody>${state.rules.map((r,i)=>`<tr><td class="code">${escapeHTML(r.domain)}</td><td class="muted">${escapeHTML(r.kind)}</td><td>${pill(actionNames[r.action],r.action==='proxy'?'blue':'neutral')}</td><td>${button('删除',`delete-rule:${i}`)}</td></tr>`).join('')}</tbody></table></div>`)+
 `<div class="columns">${card('基础策略',row('内网与本地域名','保留局域网、打印机和已有 VPN 私网路径',pill('直连','neutral'))+row('国内规则集','与用户规则冲突时优先采用用户规则',pill('直连','neutral'))+row('其他公网连接','跟随当前模式与所选代理节点',pill('按规则','blue')))}${card('试一下规则',`<label class="form-label" for="rule-domain">输入域名，预览域名匹配结果</label><div class="policy-test"><input id="rule-domain" type="text" placeholder="example.org">${button('检查','rule-test')}</div><div class="policy-result" id="policy-result" role="status">这里检查域名策略，实际 IP 与连接仍需诊断。</div>`)}</div>`;
}
function remote(){return heading('远程访问','连接家中的服务，同时保留独立、固定的访问通道。',button('导入开通链接','enroll',false,'plus'))+
 `<section class="card remote-channel"><div class="tile-icon">${icon('lock')}</div><div><h2>家庭中转</h2><p>固定 AnyTLS 通道 · 当前设备：我的 Mac</p></div>${pill(remoteStatus(),state.remote?'':'neutral')}${toggle('remote',state.remote,'开启远程访问通道')}</section>`+
 `<div class="tabs" role="tablist" aria-label="远程访问分类">${[['bindings','本地入口'],['services','可访问服务'],['publish','发布服务']].map(([id,text])=>`<button role="tab" aria-selected="${state.remoteTab===id}" data-remote-tab="${id}" class="${state.remoteTab===id?'selected':''}">${text}</button>`).join('')}</div>`+
 (state.remoteTab==='bindings'?card('我的本地入口',`<div class="table-wrap"><table><thead><tr><th>服务</th><th>本地地址</th><th>状态</th><th>操作</th></tr></thead><tbody>${state.bindings.map((b,i)=>`<tr><td><div class="node-title"><div class="tile-icon">${icon('remote')}</div><div>${escapeHTML(b.name)}<small>${escapeHTML(b.service)}</small></div></div></td><td class="code">127.0.0.1:${b.port}</td><td>${pill(b.enabled&&state.remote?'可访问':'已停止',b.enabled&&state.remote?'':'neutral')}</td><td><div class="table-actions">${button('编辑',`binding:${i}`)}${button('连接',`rdp:${i}`,true)}</div></td></tr>`).join('')||'<tr><td colspan="4" class="empty">还没有本地入口。到「可访问服务」添加一个。</td></tr>'}</tbody></table></div><p class="note">本地端口只在这台 Mac 上分配。修改入口会影响正在使用该入口的连接。</p>`,button('添加入口','add-binding',false,'plus')):
 state.remoteTab==='services'?card('已授权的服务',row('家里的 Windows','家庭路由器 / desktop · RDP',button('创建本地入口','add-binding',true))+`<p class="note">可访问列表来自服务端授权。添加本地入口不会改变发布设备的目标地址。</p>`):
 card('让其他设备访问这台 Mac',`<div class="empty">${icon('lock')}<h2>当前身份只有访问权限</h2><p>发布能力由管理员授予。获得权限后，可选择本机服务并指定访问设备。</p></div>`))+
 `<div class="banner">更换上网节点、关闭系统代理或停止普通代理，不会更改这条固定通道。</div>`+
 card('通道检查',row('控制端与同步','独立证书验证 · 断线保留最后有效入口',pill(state.remote?'正常':'已停止',state.remote?'':'neutral'))+row('服务可达性','实际桌面登录还需要 Windows 账号',button('检查连接','remote-probe',false,'refresh')));
}
const connectionsData=[['Safari','www.example.org','TCP','代理','用户规则', '2.4 MB'],['Safari','www.example.cn','TCP','直连','国内规则', '812 KB'],['Terminal','api.example.net','TCP','代理','默认策略','24 KB'],['Windows App','127.0.0.1:13389','TCP','远程通道','固定入口','108 KB']];
function connectionRows(){return connectionsData.filter(c=>c.join(' ').toLowerCase().includes(state.connectionQuery.toLowerCase())).filter(c=>c[3]==='远程通道'?state.remote:state.connected).map(c=>`<tr><td>${c[0]}</td><td class="connection-domain">${c[1]}</td><td>${c[2]}</td><td>${pill(c[3],c[3]==='代理'?'blue':'neutral')}</td><td class="hint">${c[4]}</td><td class="code">${c[5]}</td></tr>`).join('')||'<tr><td colspan="6" class="empty">没有符合条件的连接</td></tr>';}
function connections(){return heading('连接','查看目的地址与匹配规则，解释流量为什么走这个出口。')+`<div class="search"><input id="connection-search" type="text" aria-label="过滤连接" placeholder="搜索应用、目标地址或策略" value="${escapeHTML(state.connectionQuery)}">${button('清空筛选','clear-search')}</div>`+card('连接记录',`<div class="table-wrap"><table><thead><tr><th>应用</th><th>目标</th><th>协议</th><th>出口</th><th>匹配规则</th><th>流量</th></tr></thead><tbody id="connection-rows">${connectionRows()}</tbody></table></div>`)+`<p class="note">系统代理模式只记录进入代理的连接。应用归属在正式版中按可取得的信息展示，无法识别时显示「未知应用」。</p>`;}
function diagnostics(){return heading('诊断','从本地入口到远端出口，逐段确认连接状态。',button('运行诊断','diagnose',true,'diagnostics'))+
 `<div class="columns">${card('上网代理',`<div class="checks">${[['配置校验',true],['本地 HTTP / SOCKS 入口',state.connected],['当前节点握手',state.connected],['代理出口请求',state.connected],['系统代理与期望一致',state.system]].map(([name,ok])=>row(name,'',state.checks?pill(ok?'通过':'未启用',ok?'':'neutral'):pill('待检查','neutral'))).join('')}</div>`)}${card('远程访问',`<div class="checks">${['固定通道握手','控制端证书与同步','STCP 本地入口','Windows RDP 协商'].map(name=>row(name,'',state.checks?pill(state.remote?'通过':'未启用',state.remote?'':'neutral'):pill('待检查','neutral'))).join('')}</div><p class="note">RDP 协商通过，不代表桌面登录、画面和剪贴板已经通过。</p>`)}</div>`+
 card('最近日志',`<div class="log">${state.logs.map(l=>`<div><span>${l[0]}</span><span>${l[1]}</span>${escapeHTML(l[2])}</div>`).join('')}</div>`,button('导出诊断包','export',false,'download'))+`<p class="note">导出前展示内容清单，默认移除密码、令牌、开通链接与私钥。</p>`;}
function settings(){return heading('设置','选择适合你的接入方式，保留清晰的恢复路径。')+`<div class="settings-grid">${card('接入与启动',row('系统代理','HTTP / HTTPS / SOCKS · 仅本机',toggle('system',state.system,'开启系统代理'))+row('登录后自动启动','启动代理；系统代理沿用明确保存的选择',toggle('autostart',state.autostart,'登录后自动启动'))+row('全设备流量接管','TUN · 后续版本，需单独授权',pill('尚未实现','neutral'))+`<p class="note">第一版提供完整的系统代理体验。忽略系统代理的应用需要单独配置本地入口。</p>`)}${card('外观与菜单栏',row('外观','支持浅色与深色',`<select id="theme-select" aria-label="外观主题"><option value="light" ${state.theme==='light'?'selected':''}>浅色</option><option value="dark" ${state.theme==='dark'?'selected':''}>深色</option></select>`)+row('菜单栏快捷操作','连接、模式、节点、远程入口',button('预览菜单','tray'))+row('关闭窗口','保留菜单栏，完整退出时停止受管进程',pill('后台运行','neutral')))}${card('DNS 与本地入口',row('本地 HTTP / SOCKS','127.0.0.1:10808 / 10809',pill('仅本机','neutral'))+row('DNS 策略','直连域名用本地解析，代理域名走代理解析',pill('随分流','blue'))+`<p class="note">DNS 保障限于进入代理的流量，不把系统代理描述为全设备 DNS 接管。</p>`)}${card('凭据与恢复',row('设备身份和节点密码','正式版保存到 macOS 钥匙串',pill('设计方案','neutral'))+row('系统代理恢复','保存原值，退出时恢复仍归本应用管理的设置',pill('自动恢复','blue'))+row('配置导出','默认只导出非敏感配置',button('预览清单','export'))+`<p class="note">原型使用示例数据；真实 secure 文件与界面源码分开保存。</p>`)}</div>`;}
const views={overview,nodes,rules,remote,connections,diagnostics,settings};
let page='overview',modalHandler=null,toastTimer;
function render(){page=location.hash.slice(1)||'overview';if(!views[page])page='overview';$('#navigation').innerHTML=navigation.map(([id,text])=>`<a href="#${id}" class="nav-item ${id===page?'active':''}" ${id===page?'aria-current="page"':''}>${icon(id)}${text}</a>`).join('');$('#breadcrumb').textContent='工作空间 / '+navigation.find(n=>n[0]===page)[1];$('#content').innerHTML=views[page]();}
function toast(message){$('#toast').textContent=message;$('#toast').classList.add('visible');clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('#toast').classList.remove('visible'),3200);}
function setTheme(theme){state.theme=theme;document.documentElement.dataset.theme=theme;}
function openModal(title,body,handler,submit='保存'){const d=$('#modal');$('#modal-title').textContent=title;$('#modal-body').innerHTML=body;$('#modal-error').textContent='';$('#modal-submit').textContent=submit;modalHandler=handler;d.showModal();}
function info(title,body){openModal(title,body,()=>true,'知道了');}
function log(message){state.logs.push([new Date().toLocaleTimeString('zh-CN',{hour12:false}),'INFO',message]);}
function importNode(enrollment=false){openModal(enrollment?'导入 Stargate 开通链接':'导入节点',`<p class="note">此原型仅演示导入流程，请使用示例链接，不要粘贴真实凭据。</p><label class="form-label" for="import-link">${enrollment?'开通链接':'AnyTLS 节点链接'}</label><textarea id="import-link" name="link" rows="4" placeholder="${enrollment?'stargate://enroll/…':'anytls://demo@node.example.com:8443/#我的节点'}" required></textarea>${button('填入示例','fill-example')}<label class="radio-line"><input type="checkbox" name="addProxy" checked>同时添加普通代理节点（不更改当前节点）</label>`,form=>{
 const link=form.get('link').trim();let url;try{url=new URL(link);}catch{throw Error('请输入有效链接，或点击「填入示例」。');}
 if(!['anytls:','stargate:'].includes(url.protocol))throw Error('目前仅预览 AnyTLS 与 Stargate 链接导入。');
 if(enrollment&&url.protocol!=='stargate:')throw Error('开通远程访问需要 stargate://enroll/ 链接。');
 if(url.protocol==='stargate:'){
  if(url.hostname!=='enroll'||!url.pathname.slice(1))throw Error('开通链接应使用 stargate://enroll/ 格式。');
  let payload;try{payload=JSON.parse(atob(url.pathname.slice(1).replace(/-/g,'+').replace(/_/g,'/')));}catch{throw Error('示例开通内容无法解析。');}
  if(payload.preview!==true)throw Error('请使用「填入示例」生成的预览链接；此处不会兑换真实凭据。');
  state.remote=true;toast('已模拟开通独立通道；当前上网节点保持不变');
 }else if(!url.hostname||!url.username||Number(url.port)<1)throw Error('节点链接需要凭据、服务器和端口。');
 if(url.protocol==='anytls:'||form.get('addProxy')){
  let name='新导入的节点';if(url.protocol==='anytls:'&&url.hash){try{name=decodeURIComponent(url.hash.slice(1));}catch{throw Error('节点名称编码无效。');}}
  state.nodes.push({id:'import-'+Date.now(),name,group:'手动导入',region:'NEW',host:url.protocol==='anytls:'?url.hostname:'new.example.com',latency:99});
 }
 toast('导入流程预览完成；未保存任何密码或兑换真实链接');return true;
 },'导入');}
function bindingModal(index){const b=state.bindings[index];openModal(b?'编辑本地入口':'添加本地入口',`<label class="form-label" for="binding-name">名称</label><input id="binding-name" name="name" type="text" maxlength="60" value="${escapeHTML(b?.name||'家里的 Windows')}" required><label class="form-label" for="binding-service">已授权服务</label><select id="binding-service" name="service"><option value="home/desktop">家庭路由器 / desktop</option></select><div class="field-grid"><div><label class="form-label" for="binding-address">本地地址</label><input id="binding-address" type="text" value="127.0.0.1" readonly></div><div><label class="form-label" for="binding-port">本地端口</label><input id="binding-port" type="number" name="port" min="1024" max="65535" value="${b?.port||13390}" required></div></div><label class="radio-line"><input name="enabled" type="checkbox" ${!b||b.enabled?'checked':''}>启用这个入口</label><p class="note">入口只属于这台访问设备。改动已有入口可能断开对应会话。</p>`,form=>{const port=Number(form.get('port'));if(!Number.isInteger(port)||port<1024||port>65535)throw Error('请输入 1024–65535 的整数端口。');if([10808,10809,10830,10831,17400].includes(port)||state.bindings.some((v,i)=>i!==index&&v.port===port))throw Error('该端口与本地代理、管理端口或其他入口冲突。');const name=form.get('name').trim();if(!name)throw Error('请输入入口名称。');const next={id:b?.id||'binding-'+Date.now(),name,service:'home/desktop',port,enabled:!!form.get('enabled')};if(b)state.bindings[index]=next;else state.bindings.push(next);toast('本地入口已更新（示例）');return true;});}
document.addEventListener('click',e=>{
 const mode=e.target.closest('[data-mode]');if(mode){state.mode=mode.dataset.mode;render();toast('上网模式已切换；远程通道保持独立');return;}
 const tab=e.target.closest('[data-remote-tab]');if(tab){state.remoteTab=tab.dataset.remoteTab;render();return;}
 const target=e.target.closest('[data-action]');if(!target)return;const [action,value]=target.dataset.action.split(':');
 switch(action){
 case 'connect':state.connected=!state.connected;if(!state.connected)state.system=false;log(state.connected?'代理已启动（示例）':'普通代理已停止，系统代理已恢复（示例）');toast(state.connected?'已模拟启动本地代理':'普通代理已停止；远程通道保持原状态');break;
 case 'system':if(!state.system&&!state.connected){toast('请先启动普通代理，再开启系统代理');return;}state.system=!state.system;toast(state.system?'系统代理已开启（示例）':'系统代理已恢复（示例）');break;
 case 'remote':state.remote=!state.remote;toast(state.remote?'独立通道已启动（示例）':'独立通道已停止；普通代理保持原状态');break;
 case 'autostart':state.autostart=!state.autostart;break;
 case 'select':state.selected=value;log('选择节点：'+currentNode().name);toast('上网节点已切换；家庭中转通道未改变');break;
 case 'latency':toast('示例延迟检测完成；此原型未发送网络请求');break;
 case 'import':importNode();return;
 case 'enroll':importNode(true);return;
 case 'fill-example':$('#import-link').value=$('#modal-title').textContent.includes('Stargate')?'stargate://enroll/'+btoa(JSON.stringify({preview:true,schema:2,device:'preview-mac'})).replace(/=/g,''):'anytls://demo@node.example.com:8443/#'+encodeURIComponent('我的新节点');return;
 case 'node':{const n=state.nodes.find(n=>n.id===value);info('节点详情',row('名称','',escapeHTML(n.name))+row('服务器','',`<span class="code">${escapeHTML(n.host)}:8443</span>`)+row('协议','',pill('AnyTLS','neutral'))+row('凭据','',pill('原型未保存','neutral'))+`<p class="note">正式版密码保存在钥匙串，节点列表与诊断日志默认脱敏。</p>`);return;}
 case 'add-rule':openModal('添加域名规则',`<label class="form-label" for="new-domain">域名或后缀</label><input id="new-domain" name="domain" type="text" placeholder="example.org" required><label class="form-label" for="new-action">策略</label><select id="new-action" name="action"><option value="proxy">代理</option><option value="direct">直连</option><option value="reject">拒绝</option></select>`,form=>{const domain=form.get('domain').trim().toLowerCase();if(!/^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(domain))throw Error('请输入域名，例如 example.org；不要包含协议或路径。');if(state.rules.some(r=>r.domain===domain))throw Error('已有相同域名规则。');state.rules.push({domain,action:form.get('action'),kind:'用户规则'});toast('域名规则已添加（示例）');return true;});return;
 case 'delete-rule':state.rules.splice(Number(value),1);toast('示例规则已删除');break;
 case 'rule-test':{const domain=$('#rule-domain').value.trim().toLowerCase();if(!domain){$('#policy-result').textContent='请输入要检查的域名。';return;}const r=[...state.rules].sort((a,b)=>b.domain.length-a.domain.length).find(r=>domain===r.domain||domain.endsWith('.'+r.domain));$('#policy-result').textContent=state.mode==='global'?'全局代理：公网 TCP 走当前节点；实际 IP 与内网例外需另验。':state.mode==='direct'?'仅直连：用户规则暂不生效。':r?`命中 ${r.domain} → ${actionNames[r.action]}。这是域名策略预览。`:'没有命中用户域名规则，需解析后继续判断 IP 与基础规则。';return;}
 case 'binding':bindingModal(Number(value));return;
 case 'add-binding':bindingModal();return;
 case 'rdp':{const b=state.bindings[Number(value)];if(!b.enabled||!state.remote){toast('先启用入口和远程通道，再连接桌面');return;}info('连接家里的 Windows',`<p class="note">正式应用会提供 Windows App 的启动入口，或生成 .rdp 文件。</p><label class="form-label">电脑地址</label><div class="log">127.0.0.1:${b.port}</div><p class="note">使用 Windows 登录账号和密码。原型不会启动桌面客户端。</p>`);return;}
 case 'remote-probe':toast(state.remote?'示例 RDP 协商通过；桌面登录需另验':'通道未启用，无法检查远端');return;
 case 'check-overview':toast(state.connected?'示例检查通过；实际网络未被探测':'普通代理未运行；远程通道可独立使用');return;
 case 'diagnose':state.checks=true;log('分层诊断完成（示例数据）');toast('诊断预览已完成');break;
 case 'export':openModal('导出诊断预览',`<p class="note">下载只包含当前原型状态和示例日志。</p>${row('包含','', '模式、状态、示例日志')}${row('排除','', '密码、令牌、私钥、开通链接')}`,()=>{const payload={preview:true,mode:state.mode,proxy:state.connected,system:state.system,remote:state.remote,logs:state.logs};const url=URL.createObjectURL(new Blob([JSON.stringify(payload,null,2)],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download='stargate-preview-diagnostics.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);toast('示例诊断文件已下载');return true;},'下载');return;
 case 'clear-search':state.connectionQuery='';break;
 case 'tray':info('菜单栏快捷面板',`<div class="row"><strong>Stargate</strong>${pill(state.connected?'代理已启动':'代理已停止',state.connected?'blue':'neutral')}</div>${row('当前节点','',escapeHTML(currentNode().name))}${row('上网模式','',modes[state.mode])}${row('系统代理','',state.system?'已开启':'已关闭')}${row('远程访问','',remoteStatus())}<p class="note">正式版还提供连接开关、节点切换、打开主窗口与完整退出。关闭窗口不等于停止代理。</p>`);return;
 }
 render();
});
document.addEventListener('input',e=>{if(e.target.id==='node-search'){state.nodeQuery=e.target.value;$('#node-rows').innerHTML=nodeRows();}if(e.target.id==='connection-search'){state.connectionQuery=e.target.value;$('#connection-rows').innerHTML=connectionRows();}});
document.addEventListener('change',e=>{if(e.target.id==='theme-select')setTheme(e.target.value);});
$('#theme-toggle').addEventListener('click',()=>{setTheme(state.theme==='light'?'dark':'light');if(page==='settings')render();});
$('#modal-form').addEventListener('submit',e=>{e.preventDefault();try{if(modalHandler?.(new FormData(e.target))){$('#modal').close();render();}}catch(error){$('#modal-error').textContent=error.message;}});
$('#close-modal').addEventListener('click',()=>$('#modal').close());$('#cancel-modal').addEventListener('click',()=>$('#modal').close());
window.addEventListener('hashchange',()=>{render();$('#content').focus({preventScroll:true});});
setTheme('light');render();
