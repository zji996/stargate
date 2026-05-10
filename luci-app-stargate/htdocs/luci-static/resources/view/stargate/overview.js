'use strict';
'require view';
'require form';
'require fs';
'require uci';

return view.extend({
  load: function() {
    return Promise.all([
      uci.load('stargate'),
      fs.exec_direct('/usr/share/stargate/stargate.sh', [ 'status' ]).catch(function(err) {
        return JSON.stringify({ service: String(err), singbox: '' });
      })
    ]);
  },

  render: function(data) {
    var status = {};
    try {
      status = JSON.parse(data[1] || '{}');
    } catch (e) {
      status = { service: data[1] || '' };
    }

    var m = new form.Map('stargate', _('Stargate'));

    var s = m.section(form.NamedSection, 'global', 'global', _('Overview'));
    s.anonymous = true;

    var dashboard = s.option(form.DummyValue, '_dashboard', '');
    dashboard.rawhtml = true;
    dashboard.cfgvalue = function() {
      return E('div', { 'class': 'stargate-dashboard' }, [
        E('style', {}, [
          '.stargate-dashboard{display:flex;flex-wrap:wrap;gap:12px;margin:8px 0 18px}',
          '.stargate-card{box-sizing:border-box;flex:1;min-width:180px;padding:16px;border:1px solid #ddd;border-radius:6px;background:rgba(127,127,127,.06);text-align:left}',
          '.stargate-card-title{display:block;font-size:12px;opacity:.72}',
          '.stargate-card-value{display:block;font-size:22px;font-weight:700;margin-top:6px;line-height:1.2}',
          '.stargate-card-note{display:block;font-size:12px;opacity:.72;margin-top:6px;line-height:1.35}',
          '.stargate-probe{cursor:pointer;color:inherit;font:inherit}',
          '.stargate-ok{color:#2dce89}.stargate-warn{color:#fb9a05}.stargate-bad{color:#fb6340}.stargate-muted{color:#8898aa}'
        ].join('')),
        E('div', { 'class': 'stargate-card' }, [
          E('span', { 'class': 'stargate-card-title' }, _('Runtime')),
          E('span', { 'class': 'stargate-card-value' }, status.service || _('unknown')),
          E('span', { 'class': 'stargate-card-note' }, status.enabled === '1' ? _('enabled') : _('disabled'))
        ]),
        E('div', { 'class': 'stargate-card' }, [
          E('span', { 'class': 'stargate-card-title' }, 'sing-box'),
          E('span', { 'class': 'stargate-card-value' }, status.singbox || _('not detected')),
          E('span', { 'class': 'stargate-card-note' }, status.config_file || '/etc/stargate/config.json')
        ])
      ]);
    };

    var enabled = s.option(form.Flag, 'enabled', _('Enable'));
    enabled.rmempty = false;

    return m.render();
  }
});
