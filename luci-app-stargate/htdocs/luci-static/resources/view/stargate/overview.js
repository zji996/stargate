'use strict';
'require view';
'require form';
'require fs';
'require uci';

return view.extend({
  load: function() {
    return Promise.all([uci.load('stargate'), fs.exec_direct('/usr/share/stargate/stargate.sh', ['status']).then(JSON.parse)]);
  },
  render: function(data) {
    var status=data[1];
    var m=new form.Map('stargate','Stargate');
    var section=m.section(form.NamedSection,'global','global',_('Overview'));
    section.anonymous=true;
    var dashboard=section.option(form.DummyValue,'_dashboard','');
    dashboard.rawhtml=true;
    dashboard.cfgvalue=function() {
      return E('div',{},[
        E('link',{rel:'stylesheet',href:L.resource('stargate-overview.css')+'?v=2'}),
        E('div',{class:'sg-overview'},[
          E('div',{class:'sg-summary'},[
            E('span',{class:'sg-runtime'},[
              E('span',{class:'sg-dot'+(status.service==='running'?' sg-dot-on':'')}),
              status.service==='running'?_('Running'):_('Stopped')
            ]),
            E('span',{class:'sg-version'},(status.singbox||'sing-box').replace(' version ', ' '))
          ]),
          status.node_ready?'':E('a',{class:'sg-empty',href:L.url('admin/services/stargate/node')},_('Add and select a node')),
          (status.aux_nodes && status.aux_nodes.length > 0) ? E('div', {style:'margin:10px 0;font-size:13px;'}, [
            E('div', {style:'font-weight:600;margin-bottom:4px;'}, _('Dedicated proxy ports:')),
            E('ul', {style:'margin:0;padding-left:18px;list-style:disc;'}, status.aux_nodes.map(function(aux) {
              var ports = [];
              if (aux.socks_port) ports.push('SOCKS ' + aux.listen + ':' + aux.socks_port);
              if (aux.http_port) ports.push('HTTP ' + aux.listen + ':' + aux.http_port);
              var suffix = aux.outbound === 'anytls-out' ? ' - ' + _('same as active node') : '';
              var displayName = aux.port_label ? (aux.port_label + ' (' + aux.label + ')') : aux.label;
              return E('li', {}, displayName + ' (' + ports.join(', ') + ')' + suffix);
            }))
          ]) : '',
          E('div',{class:'sg-probes','aria-label':_('Proxy connectivity')},['baidu','google','github'].map(function(target) {
            var label=E('span',{class:'sg-probe-result','aria-live':'polite'},_('Check'));
            return E('button',{type:'button',class:'sg-probe',click:async function(ev) {
              var button=ev.currentTarget;
              button.disabled=true;
              label.textContent=_('Checking…');
              try {
                var result=await fs.exec('/usr/share/stargate/stargate.sh',['probe',target]);
                var ok=result.code===0;
                button.dataset.result=ok?'ok':'failed';
                label.textContent=ok?((result.stdout.match(/\d+ms/)||[_('Connected')])[0]):_('Failed');
              } catch(e) { button.dataset.result='failed'; label.textContent=_('Failed'); }
              finally { button.disabled=false; }
            }},[E('span',{},({baidu:_('Baidu'),google:_('Google'),github:'GitHub'})[target]),label]);
          }))
        ])
      ]);
    };
    var enabled=section.option(form.Flag,'enabled',_('Enable Stargate'));
    enabled.default='0'; enabled.rmempty=false;
    var inbound=m.section(form.NamedSection,'inbound','inbound',_('Traffic'));
    inbound.anonymous=true;
    var transparent=inbound.option(form.Flag,'transparent_proxy',_('LAN proxy'));
    transparent.default='0'; transparent.rmempty=false;
    var netbird=inbound.option(form.Flag,'netbird_proxy',_('NetBird exit proxy'));
    netbird.default='1'; netbird.rmempty=false;
    netbird.depends('transparent_proxy','1');
    transparent.validate=function(section,value) {
      if(value==='1' && enabled.formvalue('global')!=='1') return _('Enable Stargate first');
      return true;
    };
    return m.render();
  }
});
