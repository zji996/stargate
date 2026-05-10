'use strict';
'require view';
'require form';
'require fs';

return view.extend({
  load: function() {
    return fs.exec_direct('/usr/share/stargate/stargate.sh', [ 'logs' ]).catch(function() {
      return '';
    });
  },

  render: function(logs) {
    var m = new form.Map('stargate', _('Logs'));
    m.description = _('Recent Stargate and sing-box logs.');

    var s = m.section(form.NamedSection, 'global', 'global', _('Recent logs'));
    s.anonymous = true;

    var box = s.option(form.DummyValue, '_logs', '');
    box.rawhtml = true;
    box.cfgvalue = function() {
      return E('div', {}, [
        E('style', {}, [
          '.stargate-log-box{white-space:pre-wrap;overflow:auto;max-height:560px;margin:0;padding:14px;border:1px solid rgba(127,127,127,.28);border-radius:6px;background:rgba(0,0,0,.16);font-size:12px;line-height:1.55}'
        ].join('')),
        E('pre', { 'class': 'stargate-log-box' }, logs || _('No logs'))
      ]);
    };

    return m.render();
  }
});
