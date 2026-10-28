(function () {
  'use strict';

  var $ = function (id) { return document.getElementById(id); };

  var S = {
    paused: false,
    timer: null,
    refresh: 3,
    tab: 'mon',
    hist: {},
    lastStatus: null,
    monitored: [],
    devicesTs: 0,
    discovered: null,
    ignore: [],
    scanning: false,
    cfg: null,
    nodes: [],
    nodeData: {},
    nodeTab: 'local',
    nodeFetchAt: 0,
    agentAt: {}
  };

  // ------------------------------------------------------------ 工具

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined && text !== null) n.textContent = String(text);
    return n;
  }

  function fmtBytes(v) {
    v = Number(v) || 0;
    var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0;
    while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
    return (i === 0 ? v : v.toFixed(v >= 100 ? 0 : 1)) + ' ' + u[i];
  }

  function fmtRate(v) {
    return fmtBytes(v) + '/s';
  }

  function fmtUptime(sec) {
    sec = Math.max(0, Math.floor(Number(sec) || 0));
    var d = Math.floor(sec / 86400),
        h = Math.floor((sec % 86400) / 3600),
        m = Math.floor((sec % 3600) / 60);
    if (d > 0) return d + ' 天 ' + h + ' 小时';
    if (h > 0) return h + ' 小时 ' + m + ' 分';
    return m + ' 分';
  }

  function fmtAgo(ts) {
    var t = Number(ts) || 0;
    if (!t) return '—';
    var d = Math.max(0, Math.floor(Date.now() / 1000) - t);
    return fmtAgoSec(d);
  }

  // 用服务端时间差，避免路由器与浏览器时钟不一致
  function fmtAgoSec(sec) {
    var d = Math.max(0, Math.floor(Number(sec) || 0));
    if (!d) return '—';
    if (d > 315360000) return '—';   // 超过 10 年说明时间戳缺失或时钟跳变
    if (d < 5) return '刚刚';
    if (d < 60) return d + ' 秒前';
    if (d < 3600) return Math.floor(d / 60) + ' 分钟前';
    if (d < 86400) return Math.floor(d / 3600) + ' 小时前';
    return Math.floor(d / 86400) + ' 天前';
  }

  function num(v, digits) {
    var n = Number(v);
    if (!isFinite(n)) return '—';
    return n.toFixed(digits === undefined ? 1 : digits);
  }

  function clamp(v, lo, hi) { return Math.min(hi, Math.max(lo, v)); }

  function quality(v) {
    if (v === null || v === undefined || !isFinite(Number(v))) return '';
    var x = Number(v);
    if (x >= 70) return 'bad';
    if (x >= 50) return 'warn';
    return 'good';
  }

  function rxQuality(dbm) {
    if (dbm === null || dbm === undefined) return '';
    var x = Number(dbm);
    if (x >= -27) return 'good';
    if (x >= -30) return 'warn';
    return 'bad';
  }

  function setText(id, v) {
    var n = $(id);
    if (n) n.textContent = v;
  }

  // ------------------------------------------------------------ 图表

  function drawChart(canvas, data, color, fixedMin, fixedMax) {
    if (!canvas) return;
    var dpr = window.devicePixelRatio || 1;
    var w = canvas.clientWidth || 320;
    var h = canvas.clientHeight || 90;
    if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(h * dpr);
    }
    var ctx = canvas.getContext('2d');
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);

    var lo = fixedMin, hi = fixedMax;
    if (lo === undefined || hi === undefined) {
      lo = Infinity; hi = -Infinity;
      for (var k = 0; k < data.length; k++) { lo = Math.min(lo, data[k]); hi = Math.max(hi, data[k]); }
      if (!isFinite(lo)) { lo = 0; hi = 1; }
      var pad = Math.max(1, (hi - lo) * 0.25);
      lo -= pad; hi += pad;
    }
    if (hi - lo < 0.001) hi = lo + 1;

    // 网格
    ctx.strokeStyle = 'rgba(120,155,200,0.16)';
    ctx.lineWidth = 1;
    for (var g = 1; g <= 2; g++) {
      var y = h * g / 3;
      ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(w, y); ctx.stroke();
    }

    if (data.length < 2) return;

    var step = w / Math.max(1, data.length - 1);
    function px(i) { return i * step; }
    function py(v) { return h - ((v - lo) / (hi - lo)) * h; }

    // 面积
    var grad = ctx.createLinearGradient(0, 0, 0, h);
    grad.addColorStop(0, color + '55');
    grad.addColorStop(1, color + '00');
    ctx.beginPath();
    ctx.moveTo(px(0), py(data[0]));
    for (var i = 1; i < data.length; i++) ctx.lineTo(px(i), py(data[i]));
    ctx.lineTo(px(data.length - 1), h);
    ctx.lineTo(px(0), h);
    ctx.closePath();
    ctx.fillStyle = grad;
    ctx.fill();

    // 折线
    ctx.beginPath();
    ctx.moveTo(px(0), py(data[0]));
    for (var j = 1; j < data.length; j++) ctx.lineTo(px(j), py(data[j]));
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.lineJoin = 'round';
    ctx.stroke();

    // 末点
    ctx.beginPath();
    ctx.arc(px(data.length - 1), py(data[data.length - 1]), 2.6, 0, Math.PI * 2);
    ctx.fillStyle = color;
    ctx.fill();
  }

  // ------------------------------------------------------------ 渲染

  function renderStatus(d, key) {
    key = key || 'local';
    if (key === 'local') S.lastStatus = d;

    var host = d.host || {};
    setText('hostName', (host.hostname || '未知主机') + (host.model ? ' · ' + host.model : ''));
    setText('footPort', d.port || 7752);
    if (key === 'local') {
      document.title = (host.hostname || '设备') + ' · 监控';
      if (typeof d.refresh === 'number') S.refresh = clamp(d.refresh, 1, 60);
    }

    // CPU
    var cpu = d.cpu || {};
    var usage = Number(cpu.usage) || 0;
    setText('kpiCpu', num(usage) + '%');
    setText('kpiCpuSub', cpu.source === 'cpuusage'
      ? '每核平均 · ' + (cpu.cores || []).length + ' 个核心'
      : '用户 ' + num(cpu.user) + '% · 系统 ' + num(cpu.system) + '%');
    setText('cpuValue', Math.round(usage) + '%');
    var ring = $('cpuRing');
    if (ring) {
      ring.style.setProperty('--p', clamp(usage, 0, 100));
      ring.style.setProperty('--c', usage >= 85 ? 'var(--bad)' : usage >= 60 ? 'var(--warn)' : 'var(--accent)');
    }
    var load = host.load || [];
    setText('cpuLoad', '负载 ' + (load.length ? load.join(' / ') : '—') + ' · ' + (host.cpu_model || ''));

    var cores = cpu.cores || [];
    var box = $('cores');
    if (box) {
      box.innerHTML = '';
      for (var i = 0; i < cores.length; i++) {
        var c = cores[i];
        var item = el('div', 'core');
        item.appendChild(el('b', null, Math.round(Number(c.usage) || 0) + '%'));
        var track = el('i');
        var fill = el('em');
        fill.style.width = clamp(Number(c.usage) || 0, 0, 100) + '%';
        track.appendChild(fill);
        item.appendChild(track);
        item.appendChild(el('span', null, '核 ' + (c.id !== undefined ? c.id : i)));
        box.appendChild(item);
      }
    }

    pushHistory(key, 'cpu', usage);
    drawChart($('cpuChart'), histFor(key).cpu, '#3b82f6', 0, 100);

    // 内存
    var mem = d.memory || {};
    var memPct = Number(mem.usage) || 0;
    setText('kpiMem', num(memPct) + '%');
    setText('kpiMemSub', fmtBytes((mem.used || 0) * 1024) + ' / ' + fmtBytes((mem.total || 0) * 1024));
    setText('memPct', Math.round(memPct) + '%');
    setText('memTotal', '共 ' + fmtBytes((mem.total || 0) * 1024));
    var donut = $('memDonut');
    if (donut) donut.style.setProperty('--p', clamp(memPct, 0, 100));

    var memKv = $('memKv');
    if (memKv) {
      memKv.innerHTML = '';
      addKv(memKv, '可用', fmtBytes((mem.available || 0) * 1024));
      addKv(memKv, '缓存', fmtBytes((mem.cached || 0) * 1024));
      addKv(memKv, '缓冲', fmtBytes((mem.buffers || 0) * 1024));
      if (mem.swap_total > 0) addKv(memKv, '交换', fmtBytes((mem.swap_used || 0) * 1024));
    }

    // 温度
    var temps = d.temperatures || [];
    var maxTemp = null, maxName = '';
    for (var t = 0; t < temps.length; t++) {
      var tv = Number(temps[t].value);
      if (!isFinite(tv)) continue;
      if (maxTemp === null || tv > maxTemp) { maxTemp = tv; maxName = temps[t].name; }
    }
    setText('kpiTemp', maxTemp === null ? '—' : num(maxTemp) + '°C');
    setText('kpiTempSub', maxName || '无温度传感器');
    setText('tempCount', temps.length + ' 个传感器');

    var tlist = $('tempList');
    if (tlist) {
      tlist.innerHTML = '';
      if (!temps.length) {
        tlist.appendChild(el('li', 'empty', '未读取到温度传感器'));
      } else {
        for (var q = 0; q < temps.length; q++) {
          var li = el('li');
          li.appendChild(el('span', 'tname', temps[q].name || ('sensor' + q)));
          li.appendChild(el('span', 'tval', num(temps[q].value) + ' °C'));
          var bar = el('div', 'bar ' + quality(temps[q].value));
          var fillT = el('i');
          fillT.style.width = clamp((Number(temps[q].value) || 0) / 100 * 100, 0, 100) + '%';
          bar.appendChild(fillT);
          li.appendChild(bar);
          tlist.appendChild(li);
        }
      }
    }

    // PON
    var pon = d.pon || {};
    var rx = pon.rx_dbm, tx = pon.tx_dbm, pt = pon.temp;
    setText('kpiRx', rx === null || rx === undefined ? '—' : num(rx, 2));
    setText('kpiRxSub', pon.available
      ? (pon.optical_signal === false ? (pon.state_text || '无光信号') : '光功率接收')
      : '未检测到光模块');
    setText('kpiPonTemp', pt === null || pt === undefined ? '—' : num(pt) + '°C');
    setText('kpiPonTempSub', pon.source ? '来源 ' + pon.source : '未检测到');

    setText('ponRx', rx === null || rx === undefined ? '—' : num(rx, 2));
    var ponRxEl = $('ponRx');
    if (ponRxEl) {
      ponRxEl.innerHTML = '';
      ponRxEl.appendChild(document.createTextNode(rx === null || rx === undefined ? '—' : num(rx, 2)));
      if (rx !== null && rx !== undefined) {
        ponRxEl.appendChild(el('small', null, ' dBm'));
        var qa = rxQuality(rx);
        if (qa) ponRxEl.appendChild(document.createTextNode(' '));
        if (qa) ponRxEl.appendChild(el('span', 'pill ' + qa, qa === 'good' ? '正常' : qa === 'warn' ? '偏弱' : '过低'));
      }
    }
    setText('ponTx', tx === null || tx === undefined ? '—' : num(tx, 2) + ' dBm');
    setText('ponTemp', pt === null || pt === undefined ? '—' : num(pt) + ' °C');
    setText('ponState', pon.state_text || pon.state || (pon.available ? '—' : '不可用'));
    setText('ponSource', pon.available ? (pon.source === 'ponctl' ? 'ponctl' : pon.source) : '无数据');

    var meta = $('ponMeta');
    if (meta) {
      meta.innerHTML = '';
      if (pon.available) {
        addInline(meta, '设备', pon.device || '—');
        addInline(meta, '模式', (pon.mode || '—').toUpperCase());
        if (pon.onu_id !== null && pon.onu_id !== undefined) addInline(meta, 'ONU ID', pon.onu_id);
        if (pon.voltage !== null && pon.voltage !== undefined) addInline(meta, '电压', num(pon.voltage, 2) + ' V');
        if (pon.bias !== null && pon.bias !== undefined) addInline(meta, '偏置', num(pon.bias, 2) + ' mA');
        if (pon.serial) addInline(meta, '序列号', pon.serial);
        if (pon.optical_signal === false) addInline(meta, '光信号', '无');
      } else {
        meta.textContent = pon.error || '未检测到 PON 光模块';
      }
    }

    if (rx !== null && rx !== undefined && isFinite(Number(rx))) {
      pushHistory(key, 'rx', Number(rx));
      drawChart($('rxChart'), histFor(key).rx, '#22d3ee');
      var rc = $('rxChart');
      if (rc) rc.style.opacity = '1';
    } else {
      drawChart($('rxChart'), [], '#22d3ee');
    }

    // 网络
    var net = d.net || [];
    var nb = $('netBody');
    if (nb) {
      nb.innerHTML = '';
      if (!net.length) {
        var tr0 = el('tr');
        var td0 = el('td', 'empty', '无接口数据');
        td0.colSpan = 4;
        tr0.appendChild(td0);
        nb.appendChild(tr0);
      } else {
        for (var n = 0; n < net.length; n++) {
          var it = net[n], row = el('tr');
          row.appendChild(el('td', 'mono', it.name));
          row.appendChild(el('td', 'r num', '↓ ' + fmtRate(it.rx_rate)));
          row.appendChild(el('td', 'r num', '↑ ' + fmtRate(it.tx_rate)));
          row.appendChild(el('td', 'r mono', fmtBytes(it.rx) + ' / ' + fmtBytes(it.tx)));
          nb.appendChild(row);
        }
      }
    }

    // 系统信息
    var kv = $('sysKv');
    if (kv) {
      kv.innerHTML = '';
      addKv(kv, '主机名', host.hostname || '—');
      addKv(kv, '设备型号', host.model || '—');
      addKv(kv, '固件版本', host.firmware || '—');
      addKv(kv, '内核', host.kernel || '—');
      addKv(kv, '架构', host.arch || '—');
      addKv(kv, '处理器', host.cpu_model || '—');
      addKv(kv, '核心数', host.cores || '—');
      addKv(kv, '局域网地址', host.lan_ip || '—');
    }
    setText('uptime', '已运行 ' + fmtUptime(host.uptime));

    setText('stamp', '更新于 ' + new Date().toLocaleTimeString('zh-CN', { hour12: false }));
  }

  function addKv(dl, k, v) {
    var row = el('div');
    row.appendChild(el('dt', null, k));
    row.appendChild(el('dd', null, v));
    dl.appendChild(row);
  }

  function addInline(box, k, v) {
    box.appendChild(document.createTextNode(k + '：'));
    box.appendChild(el('b', null, v));
    box.appendChild(document.createTextNode('　'));
  }

  function histFor(key) {
    if (!S.hist[key]) S.hist[key] = { cpu: [], rx: [] };
    return S.hist[key];
  }

  function pushHistory(key, metric, value) {
    var arr = histFor(key)[metric];
    arr.push(Number(value) || 0);
    while (arr.length > 60) arr.shift();
  }

  function ipNum(ip) {
    var p = String(ip).split('.');
    if (p.length !== 4) return 0;
    return ((Number(p[0]) * 256 + Number(p[1])) * 256 + Number(p[2])) * 256 + Number(p[3]);
  }

  function deviceSets() {
    var added = {}, ignored = {};
    (S.monitored || []).forEach(function (m) { added[m.ip] = 1; });
    (S.ignore || []).forEach(function (ip) { ignored[ip] = 1; });
    return { added: added, ignored: ignored };
  }

  function renderMonitored(src, refTs, readonly) {
    var list = (src || []).slice();
    refTs = refTs || 0;
    var up = 0, i;

    list.sort(function (a, b) {
      if (!!b.online !== !!a.online) return b.online ? 1 : -1;
      return String(a.name || a.ip).localeCompare(String(b.name || b.ip), 'zh-CN');
    });
    for (i = 0; i < list.length; i++) if (list[i].online) up++;

    setText('kpiDev', up + ' / ' + list.length);
    setText('kpiDevSub', readonly
      ? '远程节点 · 只读'
      : '每台设备 ' + ((S.cfg && S.cfg.main && S.cfg.main.device_interval) || 30) + ' 秒轮询');
    setText('monCount', list.length);

    var tb = $('devBody');
    if (!tb) return;
    tb.innerHTML = '';

    if (!list.length) {
      var tr = el('tr');
      var td = el('td', 'empty', readonly
        ? '该节点没有监控中的设备。'
        : '还没有监控设备。切到“发现”扫描局域网，或点右上角“添加设备”。');
      td.colSpan = 8;
      tr.appendChild(td);
      tb.appendChild(tr);
      setText('monHint', '');
      return;
    }
    setText('monHint', readonly
      ? '远程节点的设备列表为只读，增删请到该节点自己的页面操作。'
      : '删除后不再探测该设备；需要时可在“发现”里重新添加。');

    for (i = 0; i < list.length; i++) {
      var dv = list[i], row = el('tr');

      var tdS = el('td');
      var pending = dv.probed === false;
      tdS.appendChild(el('span', 'dot' + (pending ? '' : dv.online ? ' on' : '')));
      tdS.appendChild(document.createTextNode(pending ? '待探测' : dv.online ? '在线' : '离线'));
      row.appendChild(tdS);

      row.appendChild(el('td', null, dv.name || dv.ip));
      row.appendChild(el('td', 'mono', dv.ip));
      row.appendChild(el('td', 'mono', dv.mac || '—'));
      row.appendChild(el('td', null, dv.type === 'tcp' ? 'TCP ' + (dv.port || '') : 'Ping'));
      row.appendChild(el('td', 'r num', dv.online && dv.rtt ? num(dv.rtt, 1) + ' ms' : '—'));
      row.appendChild(el('td', 'r num', dv.online ? '在线' : (dv.last_seen ? fmtAgoSec(refTs - dv.last_seen) : '—')));

      var tdA = el('td');
      if (!readonly) {
        var act = el('div', 'row-actions');
        var del = el('button', 'btn danger btn-sm', '删除');
        del.type = 'button';
        del.addEventListener('click', (function (d) {
          return function () { deleteDevice(d); };
        })(dv));
        act.appendChild(del);
        tdA.appendChild(act);
      }
      row.appendChild(tdA);

      tb.appendChild(row);
    }
  }

  function renderDiscovered() {
    var d = S.discovered;
    var tb = $('discBody');
    if (!tb) return;
    tb.innerHTML = '';

    if (!d) {
      setText('discCount', '0');
      setText('discMeta', '还没有扫描');
      return;
    }

    var sets = deviceSets();
    var list = (d.devices || []).slice();

    setText('discCount', list.length);
    setText('discMeta', '扫描 ' + (d.targets || 0) + ' 个地址，发现 ' + list.length +
      ' 台在线设备' + (d.ts ? '（' + fmtAgoSec((S.devicesTs || 0) - d.ts) + '）' : ''));

    if (!list.length) {
      var tr0 = el('tr');
      var td0 = el('td', 'empty', '没有发现设备。请确认扫描网段是否正确，或设备是否屏蔽了 ICMP。');
      td0.colSpan = 7;
      tr0.appendChild(td0);
      tb.appendChild(tr0);
      return;
    }

    list.sort(function (a, b) {
      var ra = sets.added[a.ip] ? 2 : (sets.ignored[a.ip] ? 1 : 0);
      var rb = sets.added[b.ip] ? 2 : (sets.ignored[b.ip] ? 1 : 0);
      if (ra !== rb) return ra - rb;
      return ipNum(a.ip) - ipNum(b.ip);
    });

    for (var i = 0; i < list.length; i++) {
      var dv = list[i];
      var row = el('tr', sets.ignored[dv.ip] ? 'dim' : null);

      var tdS = el('td');
      tdS.appendChild(el('span', 'dot on'));
      tdS.appendChild(document.createTextNode(dv.icmp ? '在线' : '在线（ICMP 无响应）'));
      row.appendChild(tdS);

      row.appendChild(el('td', null, dv.name || '—'));
      row.appendChild(el('td', 'mono', dv.ip));
      row.appendChild(el('td', 'mono', dv.mac || '—'));
      row.appendChild(el('td', null, dv.source === 'dhcp' ? 'DHCP' : 'ARP'));
      row.appendChild(el('td', 'r num', dv.icmp && dv.rtt ? num(dv.rtt, 1) + ' ms' : '—'));

      var tdA = el('td');
      var act = el('div', 'row-actions');

      if (sets.added[dv.ip]) {
        act.appendChild(el('span', 'tag-src', '已添加'));
      } else if (sets.ignored[dv.ip]) {
        var un = el('button', 'btn ghost btn-sm', '取消忽略');
        un.type = 'button';
        un.addEventListener('click', (function (ip) {
          return function () { unignoreDevice(ip); };
        })(dv.ip));
        act.appendChild(un);
      } else {
        var add = el('button', 'btn primary btn-sm', '添加');
        add.type = 'button';
        add.addEventListener('click', (function (x) {
          return function () { addDevice({ name: x.name || '', address: x.ip, type: 'ping' }); };
        })(dv));
        var ign = el('button', 'btn ghost btn-sm', '忽略');
        ign.type = 'button';
        ign.addEventListener('click', (function (ip) {
          return function () { ignoreDevice(ip); };
        })(dv.ip));
        act.appendChild(add);
        act.appendChild(ign);
      }

      tdA.appendChild(act);
      row.appendChild(tdA);
      tb.appendChild(row);
    }

    var pending = list.filter(function (x) {
      return !sets.added[x.ip] && !sets.ignored[x.ip];
    }).length;
    var all = $('btnAddAll');
    if (all) {
      all.hidden = pending === 0;
      all.textContent = '添加全部 ' + pending + ' 台';
    }
  }

  // ------------------------------------------------------------ 数据

  function getJSON(url) {
    return fetch(url, { cache: 'no-store', credentials: 'same-origin' }).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    });
  }

  function showBanner(msg) {
    var b = $('banner');
    if (!b) return;
    if (msg) { b.textContent = msg; b.hidden = false; }
    else b.hidden = true;
  }

  function refreshDevices() {
    return getJSON('/cgi-bin/devices').then(function (d) {
      S.monitored = d.devices || [];
      S.devicesTs = d.ts || 0;
      return d;
    });
  }

  function refreshAll() {
    // 节点数据（SSH/Telnet 采集较慢）不阻塞主视图
    fetchNodes(false).then(function () { renderAll(); });

    return Promise.all([
      getJSON('/cgi-bin/status').then(function (d) {
        S.lastStatus = d;
        if (typeof d.refresh === 'number') S.refresh = clamp(d.refresh, 1, 60);
      }),
      refreshDevices()
    ]).then(function () {
      if (renderAll()) showBanner('');
    }).catch(function (err) {
      showBanner('数据获取失败：' + err.message + '（服务可能未启动）');
    });
  }

  // ------------------------------------------------------------ 远程节点

  function b64(s) {
    try { return btoa(s); } catch (e) { return btoa(unescape(encodeURIComponent(s))); }
  }

  function fetchJSON(url, headers) {
    var opt = { cache: 'no-store', mode: 'cors', headers: headers || {} };
    var ctl = null;
    if (typeof AbortController !== 'undefined') {
      ctl = new AbortController();
      opt.signal = ctl.signal;
      setTimeout(function () { try { ctl.abort(); } catch (e) {} }, 5000);
    }
    return fetch(url, opt).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    });
  }

  function fetchNodes(force) {
    var list = (S.nodes || []).filter(function (n) { return String(n.enabled) !== '0'; });
    if (!list.length) return Promise.resolve();
    if (!force && Date.now() - (S.nodeFetchAt || 0) < 5000) return Promise.resolve();
    S.nodeFetchAt = Date.now();

    return Promise.all(list.map(function (n) {
      // SSH / Telnet 节点由本机采集；未选中的节点降低采集频率，避免把老设备打挂
      if (n.type === 'ssh' || n.type === 'telnet') {
        var isSel = S.nodeTab === n.section;
        if (!force && !isSel && Date.now() - (S.agentAt[n.section] || 0) < 45000) {
          return Promise.resolve();
        }
        S.agentAt[n.section] = Date.now();

        return getJSON('/cgi-bin/agent?section=' + encodeURIComponent(n.section)).then(function (r) {
          if (r && r.ok) {
            S.nodeData[n.section] = { online: true, error: '', status: r.status, devices: null, type: n.type, ts: r.ts || 0 };
          } else {
            S.nodeData[n.section] = { online: false, error: (r && r.error) || '采集失败' };
          }
        }).catch(function (err) {
          S.nodeData[n.section] = { online: false, error: (err && err.message) || '采集失败' };
        });
      }

      // 插件节点：浏览器直连
      var base = String(n.url || '').replace(/\/+$/, '');
      var h = {};
      if (n.user) h.Authorization = 'Basic ' + b64(n.user + ':' + (n.password || ''));

      return fetchJSON(base + '/cgi-bin/status', h).then(function (st) {
        return fetchJSON(base + '/cgi-bin/devices', h).then(function (dv) {
          S.nodeData[n.section] = { online: true, error: '', status: st, devices: dv };
        }, function () {
          S.nodeData[n.section] = { online: true, error: '', status: st, devices: null };
        });
      }).catch(function (err) {
        S.nodeData[n.section] = { online: false, error: (err && err.message) || '连接失败' };
      });
    }));
  }

  function nodeName(section) {
    for (var i = 0; i < (S.nodes || []).length; i++) {
      if (S.nodes[i].section === section) return S.nodes[i].name || S.nodes[i].url;
    }
    return section;
  }

  function nodeChip(section, label, online, active, type) {
    var b = el('button', 'node-chip' + (active ? ' active' : '') + (online === false ? ' off' : ''));
    b.type = 'button';
    if (online !== null) b.appendChild(el('span', 'dot' + (online ? ' on' : '')));
    if (type === 'ssh' || type === 'telnet') {
      b.appendChild(el('span', 'tag-src', type === 'ssh' ? 'SSH' : 'TELNET'));
    }
    b.appendChild(el('span', 'nm', label));
    b.addEventListener('click', function () {
      if (S.nodeTab === section) return;
      S.nodeTab = section;
      fetchNodes(false).then(renderAll);
      renderAll();
    });
    return b;
  }

  function renderNodeBar() {
    var bar = $('nodeBar');
    if (!bar) return;
    var list = S.nodes || [];
    bar.innerHTML = '';
    if (!list.length) { bar.hidden = true; return; }

    bar.hidden = false;
    bar.appendChild(nodeChip('local', '本机', true, S.nodeTab === 'local'));
    list.forEach(function (n) {
      var nd = S.nodeData[n.section];
      var label = n.name || n.host || n.url;
      bar.appendChild(nodeChip(n.section, label, nd ? !!nd.online : null, S.nodeTab === n.section, n.type));
    });
  }

  function setTab(t) {
    S.tab = t;
    Array.prototype.forEach.call(document.querySelectorAll('#devTabs .seg-btn'), function (b) {
      b.classList.toggle('active', b.getAttribute('data-tab') === t);
    });
    var mon = $('monPane'), disc = $('discPane');
    if (mon) mon.hidden = t !== 'mon';
    if (disc) disc.hidden = t !== 'disc';
    if (t === 'disc') {
      if (S.discovered) renderDiscovered();
      fetchDiscovery(false);
    }
  }

  function applyMode(remote) {
    var addBtn = $('btnAddDev');
    if (addBtn) addBtn.hidden = remote;
    var discTab = document.querySelector('#devTabs [data-tab="disc"]');
    if (discTab) discTab.hidden = remote;
    var qa = $('quickAdd');
    if (qa && remote) qa.hidden = true;
    if (remote && S.tab !== 'mon') setTab('mon');
  }

  // 渲染当前选中节点的完整视图；返回是否成功取到数据
  function renderAll() {
    renderNodeBar();

    if (S.nodeTab === 'local') {
      if (S.lastStatus) renderStatus(S.lastStatus, 'local');
      renderMonitored(S.monitored, S.devicesTs, false);
      applyMode(false);
      return true;
    }

    var nd = S.nodeData[S.nodeTab];
    if (!nd) {
      showBanner('正在读取节点「' + nodeName(S.nodeTab) + '」…');
      return false;
    }
    if (!nd.online) {
      showBanner('节点「' + nodeName(S.nodeTab) + '」离线：' + (nd.error || '无法连接'));
      return false;
    }

    renderStatus(nd.status, S.nodeTab);
    renderMonitored(nd.devices ? nd.devices.devices : [], nd.devices ? nd.devices.ts : 0, true);
    if (!nd.devices) {
      setText('monHint', '该节点通过 ' + (nd.type === 'telnet' ? 'Telnet' : 'SSH') +
        ' 采集，只提供系统指标，不包含局域网设备列表。');
      // 显示数据新鲜度：SSH/Telnet 是定时采集的，不是实时值
      if (nd.ts) {
        setText('kpiDevSub', '远程节点 · ' + fmtAgoSec((S.devicesTs || 0) - nd.ts) + '采集');
      }
    }
    applyMode(true);
    return true;
  }

  // ------------------------------------------------------------ 发现与设备操作

  function fetchDiscovery(force) {
    if (S.scanning) return;
    S.scanning = true;
    setText('discMeta', force ? '正在重新扫描局域网…' : '正在读取扫描结果…');

    getJSON('/cgi-bin/discover' + (force ? '?rescan=1' : '')).then(function (d) {
      S.scanning = false;
      if (d && d.ok === false) {
        setText('discMeta', d.error || '扫描失败');
        return;
      }
      S.discovered = d;
      renderDiscovered();
    }).catch(function (err) {
      S.scanning = false;
      setText('discMeta', '扫描失败：' + err.message);
    });
  }

  function addDevice(p) {
    return postConfig({
      action: 'add',
      name: p.name || '',
      address: p.address,
      type: p.type || 'ping',
      port: p.port || ''
    }).then(refreshDevices).then(function () {
      renderAll();
      renderDiscovered();
    });
  }

  function deleteDevice(d) {
    if (!window.confirm('删除设备「' + (d.name || d.ip) + '」？')) return;
    postConfig({ action: 'del', address: d.ip }).then(refreshDevices).then(function () {
      renderAll();
      renderDiscovered();
    }).catch(function (err) {
      showBanner('删除失败：' + err.message);
    });
  }

  function ignoreDevice(ip) {
    postConfig({ action: 'ignore', address: ip }).then(function () {
      if (S.ignore.indexOf(ip) < 0) S.ignore.push(ip);
      renderDiscovered();
    }).catch(function (err) {
      showBanner('操作失败：' + err.message);
    });
  }

  function unignoreDevice(ip) {
    postConfig({ action: 'unignore', address: ip }).then(function () {
      S.ignore = S.ignore.filter(function (x) { return x !== ip; });
      renderDiscovered();
    }).catch(function (err) {
      showBanner('操作失败：' + err.message);
    });
  }

  function addAllDiscovered() {
    var d = S.discovered;
    if (!d) return;
    var sets = deviceSets();
    var todo = (d.devices || []).filter(function (x) {
      return !sets.added[x.ip] && !sets.ignored[x.ip];
    });
    if (!todo.length) return;
    if (!window.confirm('把 ' + todo.length + ' 台设备加入监控？')) return;

    var i = 0;
    function step() {
      if (i >= todo.length) {
        setText('discMeta', '已添加 ' + todo.length + ' 台设备');
        return refreshDevices().then(function () { renderAll(); renderDiscovered(); });
      }
      var x = todo[i++];
      setText('discMeta', '正在添加 ' + i + ' / ' + todo.length + '…');
      return postConfig({ action: 'add', name: x.name || '', address: x.ip, type: 'ping' })
        .then(step, function (err) {
          setText('discMeta', '添加失败：' + err.message + '（已添加 ' + (i - 1) + ' 台）');
        });
    }
    step();
  }

  function schedule() {
    if (S.timer) clearTimeout(S.timer);
    if (S.paused) return;
    S.timer = setTimeout(function () {
      // 后台标签页不轮询，切回前台时由 visibilitychange 立即刷新
      if (document.hidden) return schedule();
      refreshAll().then(schedule, schedule);
    }, Math.max(1, S.refresh) * 1000);
  }

  // ------------------------------------------------------------ 设置

  function openDrawer() {
    var d = $('drawer');
    if (!d) return;
    d.hidden = false;
    loadConfig();
  }

  function closeDrawer() {
    var d = $('drawer');
    if (d) d.hidden = true;
  }

  function renderNodeList(list) {
    var ul = $('nodeList');
    if (!ul) return;
    ul.innerHTML = '';
    if (!list.length) {
      ul.appendChild(el('li', 'empty', '还没有远程节点'));
      return;
    }
    list.forEach(function (n) {
      var li = el('li');
      var left = el('span');
      var label = n.name || n.host || n.url;
      left.appendChild(el('b', null, label));
      left.appendChild(document.createTextNode(' '));
      if (n.type === 'ssh' || n.type === 'telnet') {
        left.appendChild(el('span', 'tag-src', n.type.toUpperCase()));
        left.appendChild(document.createTextNode(' '));
        left.appendChild(el('span', 'url', n.host + ':' + (n.port || (n.type === 'ssh' ? 22 : 23))));
      } else {
        left.appendChild(el('span', 'url', n.url));
      }
      li.appendChild(left);

      var btn = el('button', 'btn danger btn-sm', '删除');
      btn.type = 'button';
      btn.addEventListener('click', function () {
        if (!window.confirm('删除节点「' + label + '」？')) return;
        postConfig({ action: 'node_del', section: n.section }).then(function () {
          delete S.nodeData[n.section];
          if (S.nodeTab === n.section) S.nodeTab = 'local';
          return loadConfig();
        }).then(function () {
          S.nodeFetchAt = 0;
          return refreshAll();
        }).catch(function (e) {
          setMsg('nodeMsg', e.message, 'err');
        });
      });
      li.appendChild(btn);
      ul.appendChild(li);
    });
  }

  function loadConfig() {
    return getJSON('/cgi-bin/config').then(function (c) {
      S.cfg = c;
      S.ignore = (c.main && c.main.ignore) || [];
      S.nodes = c.nodes || [];
      if (S.nodeTab !== 'local' && !S.nodes.some(function (n) { return n.section === S.nodeTab; })) {
        S.nodeTab = 'local';
      }
      renderNodeList(S.nodes);
      var f = $('formSettings');
      if (!f) return;
      var m = c.main || {}, p = c.pon || {};
      f.refresh.value = m.refresh;
      f.device_interval.value = m.device_interval;
      f.ping_timeout.value = m.ping_timeout;
      f.max_devices.value = m.max_devices;
      f.scan_interval.value = m.scan_interval;
      f.scan_max.value = m.scan_max;
      f.scan_subnet.value = m.scan_subnet || '';
      f.discover_leases.checked = !!m.discover_leases;
      f.discover_arp.checked = !!m.discover_arp;
      f.auth_user.value = m.auth_user || '';
      f.auth_password.value = '';
      f.allow_cidr.value = m.allow_cidr || '';
      f.pon_enabled.checked = !!p.enabled;
      f.pon_device.value = p.device || '';
      f.pon_sfp_iface.value = p.sfp_iface || '';
      f.pon_command.value = p.command || '';
    }).catch(function (err) {
      setMsg('formMsg', '读取配置失败：' + err.message, 'err');
    });
  }

  function loadConfigQuiet() {
    return getJSON('/cgi-bin/config').then(function (c) {
      S.cfg = c;
      S.ignore = (c.main && c.main.ignore) || [];
      S.nodes = c.nodes || [];
      if (S.nodeTab !== 'local' && !S.nodes.some(function (n) { return n.section === S.nodeTab; })) {
        S.nodeTab = 'local';
      }
      if (S.tab === 'disc') renderDiscovered();
      if (S.nodes.length) {
        S.nodeFetchAt = 0;
        return fetchNodes(true).then(renderAll);
      }
      renderAll();
    }).catch(function () { /* 忽略 */ });
  }

  function postConfig(params) {
    var body = new URLSearchParams();
    Object.keys(params).forEach(function (k) {
      if (params[k] !== undefined && params[k] !== null && params[k] !== '') body.append(k, params[k]);
    });
    return fetch('/cgi-bin/config', {
      method: 'POST',
      cache: 'no-store',
      credentials: 'same-origin',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
        'X-Requested-With': 'systemmon'
      },
      body: body.toString()
    }).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    }).then(function (j) {
      if (!j.ok) throw new Error(j.error || '保存失败');
      return j;
    });
  }

  function setMsg(id, text, cls) {
    var n = $(id);
    if (!n) return;
    n.textContent = text || '';
    n.className = 'form-msg' + (cls ? ' ' + cls : '');
  }

  // ------------------------------------------------------------ 绑定

  function bind() {
    var pause = $('btnPause');
    if (pause) {
      pause.addEventListener('click', function () {
        S.paused = !S.paused;
        pause.textContent = S.paused ? '继续' : '暂停';
        pause.classList.toggle('primary', S.paused);
        if (!S.paused) refreshAll().then(schedule);
      });
    }

    var settings = $('btnSettings');
    if (settings) settings.addEventListener('click', openDrawer);

    var drawer = $('drawer');
    if (drawer) {
      drawer.addEventListener('click', function (e) {
        if (e.target && e.target.getAttribute('data-close')) closeDrawer();
      });
    }

    var form = $('formSettings');
    if (form) {
      form.addEventListener('submit', function (e) {
        e.preventDefault();
        var p = {
          action: 'set',
          refresh: form.refresh.value,
          device_interval: form.device_interval.value,
          ping_timeout: form.ping_timeout.value,
          max_devices: form.max_devices.value,
          scan_interval: form.scan_interval.value,
          scan_max: form.scan_max.value,
          scan_subnet: form.scan_subnet.value,
          discover_leases: form.discover_leases.checked ? 1 : 0,
          discover_arp: form.discover_arp.checked ? 1 : 0,
          auth_user: form.auth_user.value,
          allow_cidr: form.allow_cidr.value,
          pon_enabled: form.pon_enabled.checked ? 1 : 0,
          pon_device: form.pon_device.value,
          pon_sfp_iface: form.pon_sfp_iface.value,
          pon_command: form.pon_command.value
        };
        if (form.auth_password.value) p.auth_password = form.auth_password.value;

        setMsg('formMsg', '保存中…', '');
        postConfig(p).then(function () {
          setMsg('formMsg', '已保存', 'ok');
          form.auth_password.value = '';
          refreshAll().then(schedule);
        }).catch(function (err) {
          setMsg('formMsg', err.message, 'err');
        });
      });
    }

    // 设备页签：已监控 / 发现
    var tabs = $('devTabs');
    if (tabs) {
      tabs.addEventListener('click', function (e) {
        var btn = e.target;
        while (btn && btn !== tabs && !btn.getAttribute('data-tab')) btn = btn.parentNode;
        if (!btn || btn === tabs) return;
        var t = btn.getAttribute('data-tab');
        if (!t || t === S.tab) return;
        setTab(t);
      });
    }

    var scan = $('btnScan');
    if (scan) scan.addEventListener('click', function () { fetchDiscovery(true); });

    var addAll = $('btnAddAll');
    if (addAll) addAll.addEventListener('click', addAllDiscovered);

    // 快速添加设备
    var qa = $('quickAdd');
    var addBtn = $('btnAddDev');
    if (addBtn && qa) {
      addBtn.addEventListener('click', function () {
        qa.hidden = !qa.hidden;
        if (!qa.hidden) qa.address.focus();
      });
    }
    var addCancel = $('btnAddCancel');
    if (addCancel && qa) {
      addCancel.addEventListener('click', function () {
        qa.hidden = true;
        qa.reset();
        setMsg('addMsg', '', '');
      });
    }
    if (qa) {
      qa.addEventListener('submit', function (e) {
        e.preventDefault();
        if (!qa.address.value.trim()) { setMsg('addMsg', '请填写地址', 'err'); return; }
        setMsg('addMsg', '添加中…', '');
        addDevice({
          name: qa.name.value,
          address: qa.address.value,
          type: qa.type.value,
          port: qa.port.value
        }).then(function () {
          setMsg('addMsg', '已添加', 'ok');
          qa.reset();
          loadConfigQuiet();
        }).catch(function (err) {
          setMsg('addMsg', err.message, 'err');
        });
      });
    }

    // 添加远程节点（插件 / SSH / Telnet）
    var nodeType = $('nodeType');
    if (nodeType) {
      var applyNodeType = function () {
        var plugin = nodeType.value === 'plugin';
        $('nodeUrl').hidden = !plugin;
        $('nodeHost').hidden = plugin;
        $('nodePort').hidden = plugin;
        $('nodePort').placeholder = nodeType.value === 'ssh' ? '22' : '23';
      };
      nodeType.addEventListener('change', applyNodeType);
      applyNodeType();
    }

    var nodeAdd = $('btnNodeAdd');
    if (nodeAdd) {
      nodeAdd.addEventListener('click', function () {
        var f = $('formSettings');
        var type = f.node_type.value;
        var url = f.node_url.value.trim();
        var host = f.node_host.value.trim();

        if (type === 'plugin' && !url) { setMsg('nodeMsg', '请填写节点地址', 'err'); return; }
        if (type !== 'plugin' && !host) { setMsg('nodeMsg', '请填写 IP 地址', 'err'); return; }

        setMsg('nodeMsg', '添加中…', '');
        postConfig({
          action: 'node_add',
          type: type,
          name: f.node_name.value,
          url: url,
          host: host,
          port: f.node_port.value,
          user: f.node_user.value,
          password: f.node_pass.value
        }).then(function () {
          setMsg('nodeMsg', '已添加', 'ok');
          f.node_name.value = '';
          f.node_url.value = '';
          f.node_host.value = '';
          f.node_port.value = '';
          f.node_user.value = '';
          f.node_pass.value = '';
          S.nodeFetchAt = 0;
          return loadConfig();
        }).then(function () {
          return refreshAll();
        }).catch(function (err) {
          setMsg('nodeMsg', err.message, 'err');
        });
      });
    }

    document.addEventListener('visibilitychange', function () {
      if (!document.hidden && !S.paused) refreshAll().then(schedule);
    });

    window.addEventListener('resize', function () {
      var k = S.nodeTab === 'local' ? 'local' : S.nodeTab;
      drawChart($('cpuChart'), histFor(k).cpu, '#3b82f6', 0, 100);
      drawChart($('rxChart'), histFor(k).rx, '#22d3ee');
    });
  }

  bind();
  loadConfigQuiet();
  refreshAll().then(schedule);
})();
