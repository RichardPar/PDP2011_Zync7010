/* panel.js - drives the PDP-11 peripheral panels from pdp11-hostd.
 *
 * Transport: a WebSocket to /ws carrying two message types - "state" (a full
 * snapshot, pushed ~10/s) and "event" (discrete things worth a log line).
 * If the socket can't be established we fall back to polling /api/state, so
 * the page still works through a proxy that eats upgrades.
 *
 * Lamps are not CSS transitions: each one carries an intensity 0..1 updated
 * every animation frame, with a fast rise and a slow decay, so activity
 * lamps flicker the way filament lamps do instead of snapping on and off.
 */
'use strict';

/* ------------------------------------------------------------------ lamps */
const lamps = new Map();       /* element -> lamp state */

function lampOf(el) {
  let L = lamps.get(el);
  if (!L) { L = { i: 0, target: 0, flash: 0 }; lamps.set(el, L); }
  return L;
}
/* steady state: on/off, with lamp-like asymmetric response */
function lampSet(el, on)  { if (el) lampOf(el).target = on ? 1 : 0; }
/* activity: kick the filament; it decays on its own */
function lampBump(el, amt) {
  if (!el) return;
  const L = lampOf(el);
  L.flash = Math.min(1, L.flash + (amt === undefined ? 1 : amt));
}

function lampFrame() {
  lamps.forEach((L, el) => {
    const d = L.target - L.i;
    L.i += d > 0 ? d * 0.55 : d * 0.16;        /* rise fast, fall slow */
    L.flash *= 0.82;
    if (L.flash < 0.004) L.flash = 0;
    const v = Math.min(1, L.i + L.flash);
    el.style.setProperty('--i', v.toFixed(3));
  });
  requestAnimationFrame(lampFrame);
}
requestAnimationFrame(lampFrame);

const $  = (s, r) => (r || document).querySelector(s);
const $$ = (s, r) => Array.from((r || document).querySelectorAll(s));
const lampIn = (root, name) => $('[data-lamp="' + name + '"]', root);

/* ---------------------------------------------------------------- helpers */
function oct(n, width) {
  let s = (n >>> 0).toString(8);
  while (s.length < (width || 0)) s = '0' + s;
  return s;
}
function bytes(n) {
  if (n === undefined || n === null || n < 0) return '';
  const u = ['B', 'KB', 'MB', 'GB'];
  let i = 0, v = n;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return (i === 0 ? v : v.toFixed(1)) + ' ' + u[i];
}
function hhmmss(s) {
  s = Math.floor(s);
  const d = Math.floor(s / 86400);
  const h = String(Math.floor(s / 3600) % 24).padStart(2, '0');
  const m = String(Math.floor(s / 60) % 60).padStart(2, '0');
  const q = String(s % 60).padStart(2, '0');
  return (d ? d + 'd ' : '') + h + ':' + m + ':' + q;
}

/* --------------------------------------------------- console address lamps */
const addrBits = [];
(function buildAddr() {
  const row = $('#addrlamps'), scale = $('#addrscale');
  for (let b = 15; b >= 0; b--) {
    const d = document.createElement('div');
    d.className = 'bit' + (b % 3 === 0 && b !== 0 ? ' sep' : '');
    row.appendChild(d);
    addrBits[b] = d;
    const s = document.createElement('span');
    s.className = (b % 3 === 0 && b !== 0 ? 'sep' : '');
    s.textContent = (b % 3 === 0) ? String(b) : '';
    if (b % 3 === 0 && b !== 0) s.style.marginRight = '7px';
    scale.appendChild(s);
  }
})();
function setAddr(v) {
  for (let b = 0; b < 16; b++) lampSet(addrBits[b], (v >> b) & 1);
}

/* ------------------------------------------------------------- messages */
/* No log pane: the panel is a status board. The latest event shows briefly
 * in the footer so a failed mount or a reset is still visible, and the full
 * record stays in the daemon's log and on the /ws event stream. */
const msgEl = $('#lastmsg');
let msgTimer = null;

function logLine(msg, level) {
  if (!msgEl) return;
  msgEl.textContent = msg;
  msgEl.className = level || '';
  if (msgTimer) clearTimeout(msgTimer);
  msgTimer = setTimeout(() => msgEl.classList.add('fade'), 6000);
  msgEl.classList.remove('fade');
}

/* --------------------------------------------------------- drive elements */
const drives = new Map();     /* "RL0" -> {root, prev, ...} */

function makeDrive(bus, u) {
  const node = $('#tpl-drive').content.cloneNode(true);
  const root = node.querySelector('.drive');
  const key  = bus.name + u.n;

  root.style.order = u.n;          /* revealed late, still sits in unit order */
  $('.sel',   root).textContent = u.n;
  $('.tag',   root).textContent = u.tag;
  $('.model', root).textContent = bus.model;

  const sel = $('.imgsel', root);
  fillSelect(sel);
  $('.btn-load',   root).addEventListener('click', () => {
    if (!sel.value) { logLine('select an image to mount first', 'warn'); return; }
    api('/load?unit=' + key.toLowerCase() + '&path=' + encodeURIComponent(sel.value),
        'mount ' + key + ' <- ' + sel.value);
  });
  $('.btn-unload', root).addEventListener('click', () =>
    api('/unload?unit=' + key.toLowerCase(), 'unmount ' + key));

  const d = {
    root: root, sel: sel,
    lamps: {
      load:  lampIn(root, 'load'),
      ready: lampIn(root, 'ready'),
      fault: lampIn(root, 'fault'),
      wp:    lampIn(root, 'wp')
    },
    el: {
      carriage: $('.carriage', root), cylmax: $('.cylmax', root),
      path: $('.path', root), size: $('.size', root),
      cyl: $('.cyl', root), blk: $('.blk', root),
      rd: $('.rd', root), wr: $('.wr', root), er: $('.er', root)
    },
    prev: { reads: 0, writes: 0, errors: 0 }, seen: false
  };
  drives.set(key, d);
  return { root: root, d: d };
}

/*
 * Which drives get a tile. The daemon decides from what's actually
 * configured - "show" is true below its min_units and for any higher unit
 * the persistent config put an image in - so a two-drive installation isn't
 * padded out with DL2/DL3 fronts that were never wired up. `revealed` is the
 * one client-side addition: the "+ DL2" button in the rack head, so a unit
 * the daemon isn't drawing can still be mounted into from here.
 */
const revealed = new Set();

function unitShown(bus, u) {
  return u.show || revealed.has(bus.name + u.n);
}

function dropDrive(key) {
  const d = drives.get(key);
  if (!d) return;
  Object.values(d.lamps).forEach(el => lamps.delete(el));
  d.root.remove();
  drives.delete(key);
}

function updateDrive(bus, u) {
  const key = bus.name + u.n;
  let d = drives.get(key);
  if (!d) {
    const made = makeDrive(bus, u);
    $(bus.name === 'RL' ? '#rl-drives' : '#rh-drives').appendChild(made.root);
    d = made.d;
  }

  /* the four legend switches, exactly as the drive front carries them:
   * LOAD lit = no pack spun up, READY = pack loaded and served,
   * FAULT = an I/O error in the last couple of seconds, WRITE PROT =
   * the image was opened read-only. */
  lampSet(d.lamps.load,  !u.loaded);
  lampSet(d.lamps.ready, u.loaded);
  lampSet(d.lamps.fault, u.err_ms >= 0 && u.err_ms < 2500);
  lampSet(d.lamps.wp,    !!u.ro);
  d.root.classList.toggle('empty', !u.loaded);
  d.root.classList.toggle('stopped', !u.loaded);

  /* mounting a revealed unit makes the daemon report show:true for it, so
   * the client-side override can be dropped and normal rules take over */
  if (u.loaded) revealed.delete(key);

  const dr = u.reads - d.prev.reads, dw = u.writes - d.prev.writes;
  const de = u.errors - d.prev.errors;
  if (d.seen && (dr || dw)) {
    /* one seek/transfer burst = one flash, scaled a little by how busy it was */
    lampBump(d.lamps.ready, Math.min(1, 0.35 + (dr + dw) * 0.08));
    lampBump(diskLamp, 0.8);
    setAddr(u.block >>> 0);
  }
  if (d.seen && de) {
    lampBump(d.lamps.fault, 1);
    lampBump(errLamp, 1);
    logLine(u.tag + ': I/O error at block ' + oct(u.block) + ' (octal)', 'err');
  }
  d.prev = { reads: u.reads, writes: u.writes, errors: u.errors };
  d.seen = true;

  const cyl = bus.sectors_per_cyl ? Math.floor(u.block / bus.sectors_per_cyl) : 0;
  const frac = bus.cyls ? Math.min(1, cyl / (bus.cyls - 1)) : 0;
  d.el.carriage.style.setProperty('--pos', frac.toFixed(4));
  d.el.cylmax.textContent = (bus.cyls - 1);

  d.el.path.textContent = u.loaded ? u.path : '— no pack loaded —';
  d.el.size.textContent = u.loaded ? bytes(u.size) : '';
  d.el.cyl.textContent  = u.loaded ? cyl : '—';
  d.el.blk.textContent  = u.loaded ? oct(u.block) : '—';
  d.el.blk.title        = 'decimal ' + u.block;
  d.el.rd.textContent   = u.reads;
  d.el.wr.textContent   = u.writes;
  d.el.er.textContent   = u.errors;
}

/* -------------------------------------------------------------------- TU58
 * tu58fs is a separate process with its own control API; the daemon polls it
 * and passes its /status through as `tu58` (null when it isn't running), and
 * proxies the control routes under /tu58/. So: no second port, no CORS, and
 * "not running" is simply a null - the whole rack stays hidden until the
 * emulator answers.
 *
 * What it can't show: tu58fs keeps no per-block transfer counters, so there
 * is nothing to flicker a lamp per read the way the disks do. MODIFIED
 * (tu58fs's `changed` - the image differs from what's on disk, SAVE writes
 * it back) is the one write-side signal available, and READY blips whenever
 * a poll shows the drive's state moved at all.
 */
const tapes = new Map();       /* "DD0" -> tile state */
let tapeImages = [];
const tapeRevealed = new Set();
const TU58_MIN_UNITS = 2;      /* a real TU58 is a two-cartridge drive */

function fillTapeSelect(sel) {
  const cur = sel.value;
  sel.innerHTML = ['<option value="">— select image —</option>'].concat(
    tapeImages.map(e =>
      '<option value="' + e.path + '" data-type="' + e.type + '">' +
      (e.type === 'dir' ? '[dir] ' : '') + e.name +
      (e.size >= 0 ? '  (' + bytes(e.size) + ')' : '') + '</option>')
  ).join('');
  sel.value = cur;
}

function refreshTapeImages() {
  fetch('/tu58/images').then(r => r.json()).then(j => {
    tapeImages = j.entries || [];
    tapes.forEach(t => fillTapeSelect(t.sel));
  }).catch(() => {});
}

function tapeApi(url, what) {
  fetch(url).then(r => r.json()).then(j => {
    const okay = j.ok !== false;
    logLine(what + ': ' + (j.message || (okay ? 'ok' : 'failed')), okay ? 'ok' : 'err');
    refreshTapeImages();
  }).catch(e => logLine(what + ': ' + e, 'err'));
}

function makeTape(u) {
  const node = $('#tpl-tape').content.cloneNode(true);
  const root = node.querySelector('.drive');
  const tag  = 'DD' + u.unit;

  root.style.order = u.unit;
  $('.sel', root).textContent = u.unit;
  $('.tag', root).textContent = tag;

  const sel = $('.imgsel', root), fssel = $('.fssel', root);
  fillTapeSelect(sel);

  $('.btn-load', root).addEventListener('click', () => {
    if (!sel.value) { logLine('select an image to mount first', 'warn'); return; }
    /* a directory is mounted as a shared drive, which needs a DEC filesystem
     * to present it through - hence the fs picker next to the image */
    const isDir = sel.selectedOptions[0].dataset.type === 'dir';
    tapeApi('/tu58/load?unit=' + u.unit + '&path=' + encodeURIComponent(sel.value) +
            (isDir ? '&shared=1&fs=' + fssel.value : ''),
            'mount ' + tag + ' <- ' + sel.value);
  });
  $('.btn-save',   root).addEventListener('click', () =>
    tapeApi('/tu58/save?unit=' + u.unit, 'save ' + tag));
  $('.btn-unload', root).addEventListener('click', () =>
    tapeApi('/tu58/unload?unit=' + u.unit, 'unmount ' + tag));

  const t = {
    root: root, sel: sel,
    lamps: {
      load:  lampIn(root, 'load'),  ready: lampIn(root, 'ready'),
      wp:    lampIn(root, 'wp'),    mod:   lampIn(root, 'mod')
    },
    el: {
      path: $('.path', root), size: $('.size', root), fs: $('.fs', root),
      blocks: $('.blocks', root), mode: $('.mode', root),
      fslabel: $('.fslabel', root)
    },
    prev: '', seen: false
  };
  tapes.set(tag, t);
  $('#tu-drives').appendChild(root);
  return t;
}

function dropTape(tag) {
  const t = tapes.get(tag);
  if (!t) return;
  Object.values(t.lamps).forEach(el => lamps.delete(el));
  t.root.remove();
  tapes.delete(tag);
}

function updateTape(u, offline) {
  const tag = 'DD' + u.unit;
  const t = tapes.get(tag) || makeTape(u);
  const sig = JSON.stringify(u);

  lampSet(t.lamps.load,  !u.loaded);
  lampSet(t.lamps.ready, u.loaded && !offline);
  lampSet(t.lamps.wp,    !!u.readonly);
  lampSet(t.lamps.mod,   !!u.changed);
  t.root.classList.toggle('empty', !u.loaded);

  /* no transfer counters exist upstream; a state change is the only honest
   * activity signal, so blip READY on one */
  if (t.seen && sig !== t.prev) lampBump(t.lamps.ready, 0.6);
  if (t.seen && sig !== t.prev && u.changed) lampBump(t.lamps.mod, 1);
  t.prev = sig;
  t.seen = true;

  t.el.path.textContent   = u.loaded ? u.path : '— no cartridge —';
  t.el.size.textContent   = u.loaded && u.size >= 0 ? bytes(u.size) : '';
  const fs = (u.filesystem && u.filesystem !== 'none') ? u.filesystem : null;
  t.el.fs.textContent     = u.loaded ? (fs || '—') : '—';
  t.el.blocks.textContent = u.loaded && u.blocks !== undefined ? u.blocks : '—';
  t.el.mode.textContent   = !u.loaded ? '—'
                          : (u.shared ? 'SHARED DIR' : 'IMAGE') +
                            (u.readonly ? ' / RO' : '');
  /* the cartridge's paper label: the DEC filesystem if it has one, else
     just the drive type - "NONE" on a label reads as a fault, not a raw image */
  t.el.fslabel.textContent = u.loaded ? (fs ? fs.toUpperCase() : 'TU58') : '—';
}

function updateTu58(tu) {
  const rack = $('#rack-tu58');

  /* tu58fs isn't running: no rack at all, rather than an empty one that
   * looks like broken hardware */
  if (!tu) {
    if (!rack.hidden) {
      rack.hidden = true;
      tapes.forEach((_, tag) => dropTape(tag));
      logLine('tu58fs went away — tape panel hidden', 'warn');
    }
    return;
  }
  if (rack.hidden) {
    rack.hidden = false;
    logLine('tu58fs detected on ' + (tu.serial ? tu.serial.port : '?') +
            ' — tape panel shown', 'ok');
    refreshTapeImages();
  }

  lampSet(lampIn(document, 'tu-online'),  true);
  lampSet(lampIn(document, 'tu-offline'), !!tu.offline);
  $('#tu-stat').textContent = (tu.serial ? tu.serial.port + ' @ ' + tu.serial.baud : '') +
                              (tu.offline ? ' · drives offline' : '') +
                              ' · polled 1/s';

  const off = $('#tu-offbtn');
  off.textContent = tu.offline ? 'BRING ONLINE' : 'TAKE OFFLINE';
  off.onclick = () => tapeApi('/tu58/offline?state=' + (tu.offline ? 0 : 1),
                              tu.offline ? 'bring drives online' : 'take drives offline');

  const units = tu.units || [];
  const shown = u => u.loaded || u.unit < TU58_MIN_UNITS || tapeRevealed.has(u.unit);
  units.forEach(u => { if (shown(u)) updateTape(u, tu.offline); else dropTape('DD' + u.unit); });

  const next = units.find(u => !shown(u));
  const add = $('#tu-add');
  add.hidden = !next;
  if (next) {
    add.textContent = '+ DD' + next.unit;
    add.onclick = () => { tapeRevealed.add(next.unit); updateTu58(tu); };
  }
}

/* ------------------------------------------------------------ net metering */
const SEGS = 10;
function buildBars(id, colors) {
  const host = $(id), segs = [];
  for (let i = 0; i < SEGS; i++) {
    const s = document.createElement('div');
    s.className = 'seg';
    s.style.setProperty('--sc', colors[i < 6 ? 0 : (i < 9 ? 1 : 2)]);
    host.appendChild(s);
    segs.push(s);
  }
  return segs;
}
const barsTx = buildBars('#bars-tx', ['var(--lamp-green)', 'var(--lamp-amber)', 'var(--lamp-red)']);
const barsRx = buildBars('#bars-rx', ['var(--lamp-green)', 'var(--lamp-amber)', 'var(--lamp-red)']);

/* log scale: 1 pps lights one segment, ~1000 pps lights them all */
function setBars(segs, pps) {
  const lit = pps <= 0 ? 0 : Math.min(SEGS, 1 + Math.log10(pps) * (SEGS - 1) / 3);
  for (let i = 0; i < SEGS; i++) {
    const v = Math.max(0, Math.min(1, lit - i));
    lampOf(segs[i]).target = v;
  }
}

const diskLamp = lampIn(document, 'disk');
const netLamp  = lampIn(document, 'netio');
const errLamp  = lampIn(document, 'err');
const linkLamp = lampIn(document, 'link');

let netPrev = null;

/*
 * RUN means "the guest is driving this device" - NOT "xu0 is powered".
 *
 * It used to follow heartbeat_alive, which is the free-running counter in
 * xu0's own clock domain: alive whenever the fabric is up, whether or not
 * anything on the PDP-11 side has ever touched the DEUNA. So RUN sat lit
 * next to run_start = 0, while the receive ring filled with broadcast that
 * nothing was draining and rx_drop_qfull climbed for hours. The lamp was
 * hiding exactly the condition it should have been showing.
 *
 * run_start only advances when the microcode runs a DMA cycle for a driver,
 * so that - not the heartbeat - is what RUN reflects now.
 */
const RUN_IDLE_MS = 2500;   /* an active driver cycles far faster than this */

function driverState(n) {
  if (!n.present)            return { run: false, text: 'no UIO device — built without have_xu_net?' };
  if (!n.hb_alive)           return { run: false, text: 'xu0 heartbeat stalled' };
  if (!n.run_start)          return { run: false, text: 'xu0 idle · no driver started' };
  if (n.run_idle_ms < 0 ||
      n.run_idle_ms >= RUN_IDLE_MS)
                             return { run: false, text: 'xu0 idle · driver quiet' };
  return { run: true, text: 'xu0 · driver active' };
}

function updateNet(n) {
  const rack = $('#rack-net');
  const st = driverState(n);
  rack.classList.toggle('absent', !n.present);
  lampSet(lampIn(document, 'net-online'), n.present);
  $('#net-stat').textContent = st.text;

  lampSet(lampIn(document, 'n-run'), st.run);
  lampSet(lampIn(document, 'n-carr'), n.present && !!n.if);
  lampSet(lampIn(document, 'n-dma'),  n.present && n.dma_state !== 0);

  if (netPrev) {
    const dtx = n.tx_frames - netPrev.tx_frames;
    const drx = n.rx_frames - netPrev.rx_frames;
    const ddr = (n.drops.bcast + n.drops.other + n.drops.rxq + n.drops.txq) -
                (netPrev.drops.bcast + netPrev.drops.other +
                 netPrev.drops.rxq + netPrev.drops.txq);
    if (dtx) { lampBump(lampIn(document, 'n-xmit'), 1); lampBump(netLamp, 0.7); }
    if (drx) { lampBump(lampIn(document, 'n-recv'), 1); lampBump(netLamp, 0.7); }
    if (ddr) lampBump(lampIn(document, 'n-drop'), 0.8);
  }
  netPrev = n;

  setBars(barsTx, n.tx_pps);
  setBars(barsRx, n.rx_pps);

  $('#n-mac').textContent   = n.mac;
  $('#n-if').textContent    = n.if + (n.present ? '' : ' (idle)');
  $('#n-ip').textContent    = (n.ip && n.ip !== '0.0.0.0') ? n.ip : 'not learned yet';
  $('#n-pcsr').textContent  = oct(n.pcsr0, 6) + '  st ' + n.dma_state;
  $('#n-txf').textContent   = n.tx_frames;
  $('#n-txb').textContent   = bytes(n.tx_bytes);
  $('#n-txr').textContent   = n.tx_pps.toFixed(1);
  $('#n-rxf').textContent   = n.rx_frames;
  $('#n-rxb').textContent   = bytes(n.rx_bytes);
  $('#n-rxr').textContent   = n.rx_pps.toFixed(1);
  $('#n-dbc').textContent  = n.drops.bcast;
  $('#n-doth').textContent = n.drops.other;
  $('#n-drxq').textContent = n.drops.rxq;
  $('#n-dtxq').textContent = n.drops.txq;
}

/* ---------------------------------------------------------------- render */
let lastSeen = {};

function render(s) {
  $('#uptime').textContent  = hhmmss(s.uptime_s);
  $('#viewers').textContent = s.clients;
  $('#lastreset').textContent = (s.reset_ms >= 0) ? hhmmss(s.reset_ms / 1000) : 'not since boot';
  $('#hostline').textContent = s.host + ' — pid ' + s.pid;

  s.buses.forEach(bus => {
    const rack = $(bus.name === 'RL' ? '#rack-rl' : '#rack-rh');
    rack.classList.toggle('absent', !bus.present);
    lampSet(lampIn(document, bus.name.toLowerCase() + '-online'), bus.present);

    const busy = bus.units.some(u => u.idle_ms >= 0 && u.idle_ms < 400);
    lampSet(lampIn(document, bus.name.toLowerCase() + '-busy'), busy);

    $('#' + bus.name.toLowerCase() + '-stat').textContent = bus.present
      ? (bus.served + ' requests · ' + bus.sector_bytes + ' B/sector')
      : 'no UIO device';

    bus.units.forEach(u => {
      if (unitShown(bus, u)) updateDrive(bus, u);
      else dropDrive(bus.name + u.n);
    });

    /* offer the lowest unit that has no tile, if there is one */
    const next = bus.units.find(u => !unitShown(bus, u));
    const btn = $('#' + bus.name.toLowerCase() + '-add');
    if (btn) {
      btn.hidden = !next;
      if (next) {
        btn.textContent = '+ ' + next.tag;
        btn.onclick = () => {
          revealed.add(bus.name + next.n);
          logLine(next.tag + ': drive added to the panel — mount an image to keep it',
                  'warn');
          fetch('/api/state').then(r => r.json()).then(render).catch(() => {});
        };
      }
    }
  });

  updateNet(s.net);
  updateTu58(s.tu58);
  lampSet(linkLamp, true);
}

/* ----------------------------------------------------------- RESET switch
 * Pulses the PDP-11-only reset (POST /reset) - the same thing the init
 * script's -r does at boot and the U15 button does in hardware. Linux, this
 * daemon and the mounted disks are untouched; the PDP-11 simply reboots from
 * whatever is in DL0/DB0.
 *
 * Guarded by an arm/fire pair rather than a confirm() dialog: anything that
 * can reach this page can reboot the machine with this button, and a stray
 * click while RT-11 is running should not be able to do it. The armed state
 * lapses on its own after a few seconds.
 */
const resetBtn = $('#resetbtn');
let resetArmed = 0, resetTimer = null;

function disarmReset() {
  resetArmed = 0;
  if (resetTimer) { clearTimeout(resetTimer); resetTimer = null; }
  resetBtn.classList.remove('armed');
  $('.cap', resetBtn).textContent = 'RESET';
  $('.sub', resetBtn).textContent = 'PDP-11';
}

resetBtn.addEventListener('click', () => {
  if (!resetArmed) {
    resetArmed = 1;
    resetBtn.classList.add('armed');
    $('.cap', resetBtn).textContent = 'CONFIRM';
    $('.sub', resetBtn).textContent = 'PRESS AGAIN';
    logLine('RESET armed — press again within 5s to reset the PDP-11', 'warn');
    resetTimer = setTimeout(() => {
      logLine('RESET disarmed (timed out)', '');
      disarmReset();
    }, 5000);
    return;
  }
  disarmReset();
  resetBtn.disabled = true;
  fetch('/reset').then(r => r.json()).then(j => {
    logLine('RESET: ' + (j.message || (j.ok ? 'ok' : 'failed')), j.ok ? 'ok' : 'err');
  }).catch(e => logLine('RESET: ' + e, 'err'))
    .finally(() => setTimeout(() => { resetBtn.disabled = false; }, 3200));
});

/* ------------------------------------------------------------------- API */
function api(url, what) {
  fetch(url).then(r => r.json()).then(j => {
    if (j.error) logLine(what + ': ' + j.error, 'err');
    else { logLine(what + ': ok', 'ok'); refreshImages(); }
  }).catch(e => logLine(what + ': ' + e, 'err'));
}

/* The image list arrives independently of the state snapshot, and a drive
 * element may be built either before or after it - so keep the last list and
 * apply it to whichever selects exist now, plus to each new one. */
let imageList = [];

function fillSelect(sel) {
  const cur = sel.value;
  sel.innerHTML = ['<option value="">— select image —</option>'].concat(
    imageList.map(im =>
      '<option value="' + im.path + '">' + im.name + '  (' + bytes(im.size) + ')</option>')
  ).join('');
  sel.value = cur;
}

function refreshImages() {
  fetch('/images').then(r => r.json()).then(j => {
    imageList = j.images || [];
    drives.forEach(d => fillSelect(d.sel));
  }).catch(() => { /* image dir unreadable; the selects just stay empty */ });
}

/* ------------------------------------------------------------- transport */
const feed = $('#feed');
let ws = null, pollTimer = null, backoff = 500;

function startPolling() {
  if (pollTimer) return;
  feed.className = 'poll';
  feed.textContent = 'polling /api/state';
  pollTimer = setInterval(() => {
    fetch('/api/state').then(r => r.json()).then(render).catch(() => {
      feed.className = 'dead';
      feed.textContent = 'daemon unreachable';
      lampSet(linkLamp, false);
    });
  }, 400);
}
function stopPolling() {
  if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
}

function connect() {
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  try { ws = new WebSocket(proto + '//' + location.host + '/ws'); }
  catch (e) { startPolling(); return; }

  ws.onopen = () => {
    stopPolling();
    backoff = 500;
    feed.className = 'live';
    feed.textContent = 'live · websocket';
    logLine('websocket connected', 'ok');
  };
  ws.onmessage = ev => {
    let m;
    try { m = JSON.parse(ev.data); } catch (e) { return; }
    if (m.type === 'event') logLine(m.msg, m.level);
    else render(m);
  };
  ws.onclose = () => {
    lampSet(linkLamp, false);
    feed.className = 'dead';
    feed.textContent = 'websocket closed · retrying';
    startPolling();
    backoff = Math.min(8000, backoff * 2);
    setTimeout(connect, backoff);
  };
  ws.onerror = () => { try { ws.close(); } catch (e) {} };
}

/* first paint from the REST snapshot so the panel is populated even before
 * the socket opens (and on a browser where it never will) */
fetch('/api/state').then(r => r.json()).then(s => { render(s); refreshImages(); })
                   .catch(() => {});
connect();
setInterval(refreshImages, 30000);
