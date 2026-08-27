/* engineshelf manager — talks to gui/server.py (or gui/server.ps1 on Windows).

   The page is an app shell rather than a scrolling document: header, launch
   options, sidebar and status bar are fixed, and only the shelf in the middle
   scrolls. That is what keeps the running-job bar and the filters on screen
   while a 140 MB download crawls along. */

const $ = (id) => document.getElementById(id);

/* ---------- icons ----------
   Drawn inline rather than pulled from an icon font: the manager has to render
   before the machine has any network, and a missing glyph would leave unlabelled
   buttons. Every icon is a 24-grid stroke drawing so they share one weight. */

const ICONS = {
  disk: '<rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 7.5h.01"/><path d="M7 16.5h.01"/>',
  warn: '<circle cx="12" cy="12" r="9"/><path d="M12 8v4.5"/><path d="M12 16.2v.01"/>',
  ok: '<circle cx="12" cy="12" r="9"/><path d="M8.2 12.3l2.6 2.6 5-5.2"/>',
  theme:
    '<circle cx="12" cy="12" r="9"/><path d="M12 3a9 9 0 0 0 0 18z" fill="currentColor" stroke="none"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  link: '<path d="M9.5 14.5l5-5"/><path d="M11 7.6l1.4-1.4a3.5 3.5 0 0 1 5 5L16 12.5"/><path d="M13 16.4l-1.4 1.4a3.5 3.5 0 0 1-5-5L8 11.5"/>',
  frame:
    '<path d="M4 9V5h4"/><path d="M20 9V5h-4"/><path d="M4 15v4h4"/><path d="M20 15v4h-4"/>',
  gpu: '<rect x="5" y="5" width="14" height="14" rx="3"/><rect x="9" y="9" width="6" height="6" rx="1.5"/><path d="M9 2.6V5M15 2.6V5M9 19v2.4M15 19v2.4M2.6 9H5M2.6 15H5M19 9h2.4M19 15h2.4"/>',
  'caret-down': '<path d="M6 9.5l6 6 6-6"/>',
  check: '<path d="M20 6.5L9.5 17 4 11.5"/>',
  search: '<circle cx="11" cy="11" r="6.5"/><path d="M16 16l4.5 4.5"/>',
  x: '<path d="M6 6l12 12M18 6L6 18"/>',
  // Withdrawn rather than missing: the circle-slash everything uses for "this is
  // no longer on offer", which at badge size reads where a struck-through
  // download arrow turns into a smudge.
  barred: '<circle cx="12" cy="12" r="9"/><path d="M5.7 18.3L18.3 5.7"/>',
  calendar:
    '<rect x="3.5" y="5" width="17" height="15" rx="2.5"/><path d="M3.5 10h17"/><path d="M8.5 3.5v3"/><path d="M15.5 3.5v3"/>',
  // A note too long for the row, opened in full. Two chevrons rather than an
  // ellipsis: an ellipsis in a row of pills reads as "there is more text here",
  // which is true but not that it can be opened.
  expand: '<path d="M4 14v6h6"/><path d="M20 10V4h-6"/><path d="M4.5 19.5L10 14"/><path d="M19.5 4.5L14 10"/>',
  // This machine, as opposed to a container: a screen on a stand. A triangle was
  // tried first and read as a play button rather than as a place.
  desktop:
    '<rect x="3" y="4.5" width="18" height="12.5" rx="2.5"/><path d="M8.5 20.5h7"/><path d="M12 17v3.5"/>',
  sort: '<path d="M7 4v16M7 20l-3-3M7 20l3-3"/><path d="M17 20V4M17 4l-3 3M17 4l3 3"/>',
  grid: '<rect x="4" y="4" width="6.5" height="6.5" rx="1.6"/><rect x="13.5" y="4" width="6.5" height="6.5" rx="1.6"/><rect x="4" y="13.5" width="6.5" height="6.5" rx="1.6"/><rect x="13.5" y="13.5" width="6.5" height="6.5" rx="1.6"/>',
  rows: '<rect x="4" y="5" width="16" height="4" rx="1.4"/><rect x="4" y="12.5" width="16" height="4" rx="1.4"/>',
  'play-circle':
    '<circle cx="12" cy="12" r="9"/><path d="M10.3 9.2l4.7 2.8-4.7 2.8z" fill="currentColor" stroke="none"/>',
  dots: '<circle cx="5.5" cy="12" r="1.4" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1.4" fill="currentColor" stroke="none"/><circle cx="18.5" cy="12" r="1.4" fill="currentColor" stroke="none"/>',
  download:
    '<path d="M12 4v10"/><path d="M8 10.5l4 4 4-4"/><path d="M4.5 18.5h15"/>',
  play: '<path d="M8 5.5l11 6.5-11 6.5z" fill="currentColor" stroke="none"/>',
  stop: '<rect x="6.5" y="6.5" width="11" height="11" rx="2.5"/>',
  reset: '<path d="M20 12a8 8 0 1 1-2.4-5.7"/><path d="M20.5 4v5h-5"/>',
  cube: '<path d="M12 3l8 4.5v9L12 21l-8-4.5v-9z"/><path d="M12 21v-9"/><path d="M4 7.5l8 4.5 8-4.5"/>',
  trash:
    '<path d="M4.5 7h15"/><path d="M9.5 7V4.8h5V7"/><path d="M6.5 7l1 12.2h9l1-12.2"/>',
  terminal:
    '<rect x="3" y="4.5" width="18" height="15" rx="2.5"/><path d="M7.5 9.5l3 2.7-3 2.7"/><path d="M12.5 15.5h4"/>',
  empty:
    '<rect x="3" y="6" width="18" height="14" rx="3"/><path d="M3 10h18"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5.2l3 2"/>',
  'down-circle':
    '<circle cx="12" cy="12" r="9"/><path d="M12 7.5v8"/><path d="M8.5 12l3.5 3.5 3.5-3.5"/>',

  /* One mark per engine, on the same 24-grid stroke as the rest so a row does
     not suddenly carry a heavier glyph: Chromium's pinwheel, Firefox's flame,
     Edge's "e", and a globe for WebKit. Each is tinted by CSS - the shape alone
     was not enough to tell them apart at row size.

     WebKit gets the globe rather than Safari's compass, and violet rather than
     Safari's blue. The compass would claim the one thing this project is careful
     not to claim, and blue is already Chromium's: side by side at 20px the
     pinwheel and a blue globe read as the same icon. */
  chromium:
    '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3.6"/><path d="M12 15.6V21M8.88 10.2 4.2 7.5M15.12 10.2l4.68-2.7"/>',
  firefox:
    '<path d="M12 21.2c-3.8 0-6.8-2.9-6.8-6.5 0-4.5 4.1-6.1 4.1-9.7 0-.9-.2-1.7-.6-2.4 3.3.8 5.5 3.3 5.5 6.2 0 1.3-.5 2.4-1.4 3.1.9-.3 1.7-.9 2.2-1.7 1.2 1.4 1.9 3 1.9 4.5 0 3.6-3 6.5-6.9 6.5z"/><path d="M12 21.2c-1.9 0-3.4-1.5-3.4-3.3 0-2.3 2.2-3 2.2-5.2 2.4 1 4.6 3 4.6 5.2 0 1.8-1.5 3.3-3.4 3.3z"/>',
  edge: '<path d="M19.6 16.4A8.6 8.6 0 1 1 20.5 11.4H8.6"/><path d="M8.6 11.4C5.3 11.4 3 13.7 3 16.4c0 2.9 2.6 4.9 6.4 4.9 2.6 0 5-.9 6.6-2.3"/>',
  webkit:
    '<circle cx="12" cy="12" r="9"/><path d="M3 12h18"/><ellipse cx="12" cy="12" rx="4.2" ry="9"/>',
};

/* Kept in the order gui/server.py lists them, so the sidebar and the CLI's own
   help name the engines in one order. */
const ENGINE_ORDER = ['chromium', 'firefox', 'edge', 'webkit'];
const ENGINE_NAMES = {
  chromium: 'Chromium',
  firefox: 'Firefox',
  edge: 'Edge',
  webkit: 'WebKit',
};

const engineName = (id) => ENGINE_NAMES[id] || id || 'Chromium';

// The tint is a CSS variable picked by the attribute, so light and dark can
// carry different values without the page knowing which one is showing.
function engineMark(engine) {
  const span = document.createElement('span');
  span.className = 'eicon';
  span.dataset.engine = engine;
  span.innerHTML = icon(ENGINE_NAMES[engine] ? engine : 'cube');
  span.title = engineName(engine);
  return span;
}

const icon = (name) =>
  `<svg class="i" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" ` +
  `stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICONS[name] || ICONS.empty}</svg>`;

function paintIcons(root) {
  for (const holder of (root || document).querySelectorAll('[data-icon]')) {
    holder.innerHTML = icon(holder.dataset.icon);
  }
}

const iconSpan = (name) => {
  const span = document.createElement('span');
  span.innerHTML = icon(name);
  span.style.display = 'flex';
  return span;
};

/* ---------- theme ---------- */

const THEME_KEY = 'engineshelf.theme';

function readStored(key) {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}
function writeStored(key, value) {
  try {
    localStorage.setItem(key, value);
  } catch {
    /* private mode: not worth failing over */
  }
}

(function bootTheme() {
  const stored = readStored(THEME_KEY);
  if (stored === 'light' || stored === 'dark')
    document.documentElement.dataset.theme = stored;
})();

/* ---------- shared state ---------- */

let TOKEN = null;
let state = null;
let openMenu = null; // the row overflow menu, if one is open
let watching = null; // job id currently shown in the log panel
let watchedTitle = ''; // its name, kept so a finished job keeps its tab
let pollFailures = 0; // consecutive failed polls of the watched job
const jobInfo = new Map(); // job id -> {phase, percent, detail} read out of its output
// Every job this window has seen, newest first, running or not. The tab strip
// used to be built from the running list alone, plus the one job being watched -
// so a Docker container's log vanished the moment the next one was started,
// because starting a container is a job that ends as soon as the desktop
// answers. The server keeps the output of a finished job for as long as it lives;
// this is what keeps it reachable.
const jobSeen = new Map(); // job id -> {id, kind, revision, label, done}
const JOB_TABS = 6; // how many fit across the strip before the oldest drops off
const dropdowns = [];



// The query string can name what the page opens on, so a particular shelf can be
// linked to and so each of these is reachable without driving the controls.
const asked = (name, allowed) => {
  const value = new URLSearchParams(location.search).get(name);
  return allowed.includes(value) ? value : null;
};

const view = {
  filter: asked('filter', ['all', 'installed', 'running']) || 'all',
  engine: asked('engine', ENGINE_ORDER.concat('all')) || 'all',
  query: '',
  // Read before the sort dropdown is built, so its label agrees with the order
  // the shelf is actually in.
  sort: asked('sort', ['new', 'old', 'disk']) || 'old',
  gpu: 'auto',
};

// What each version was first to support, keyed "<engine>:<id>". Fetched once,
// from its own endpoint rather than out of the state document: it describes
// releases that already happened, so re-sending 146 KB of it every second a job
// runs would be 146 KB an hour of nothing changing. Empty until it arrives, and
// empty for good if the server has no features.tsv - the rows then read exactly
// as they did before any of this existed.
let featureIndex = {};

const stopping = new Set(); // jobs the user has asked to stop or cancel

// Four engines name platforms four different ways and not one of the names is
// meant to be read: "mac-26-arm64" is a Playwright SDK target, "Mac_Universal" a
// Microsoft package name, "Mac_Arm" a Chromium snapshot directory.
// Read inside a sentence now rather than printed on a pill, which is why arm64 is
// not spelled "native arm64" any more: "runs on this machine (native arm64)" says
// native twice.
const PLATFORM_LABELS = {
  Mac_Arm: 'arm64',
  Mac: 'x86_64',
  Linux_x64: 'Linux x86_64',
  Win_x64: 'Windows x86_64',
  Mac_Universal: 'macOS universal',
  mac: 'macOS',
  'linux-x86_64': 'Linux x86_64',
  win64: 'Windows x86_64',
};

// Playwright publishes one WebKit archive per macOS release and per Ubuntu LTS,
// spelling out arm64 and leaving x86_64 unmarked - so those two families are
// patterns rather than table entries. Anything unrecognised is printed as it
// came, which is still more use than a guess.
function platformLabel(dir) {
  const name = String(dir || '');
  if (!name || name === '?') return '';
  if (PLATFORM_LABELS[name]) return PLATFORM_LABELS[name];
  let found = name.match(/^mac-(\d+)(-arm64)?$/);
  if (found) return `macOS ${found[1]} · ${found[2] ? 'arm64' : 'x86_64'}`;
  found = name.match(/^ubuntu-([\d.]+)(-arm64)?$/);
  if (found) return `Ubuntu ${found[1]} · ${found[2] ? 'arm64' : 'x86_64'}`;
  return name;
}

// What a job is doing, in the words the row and the status bar use. The phase
// read from the output wins; the endpoint that started the job is the fallback.
const WORK_WORD = {
  downloading: 'downloading',
  extracting: 'extracting',
  ready: 'starting',
  open: 'running',
  install: 'installing',
  launch: 'starting',
  remove: 'removing',
  clean: 'resetting',
  docker: 'docker',
};

// Which jobs the manager offers to interrupt. A download or an image build is
// minutes of work with nothing lost by calling it off; a delete or a profile
// reset is over in a moment and cutting one short leaves half a directory.
const CANCELLABLE = new Set(['install', 'launch', 'docker']);

const workWord = (job, info) =>
  (info && WORK_WORD[info.phase]) || WORK_WORD[job.kind] || 'working';
const capitalise = (word) => word.charAt(0).toUpperCase() + word.slice(1);

// Job labels are built by the server, which only knows the selector it was
// given; the page knows which release that is. It matters most for WebKit, where
// the selector is a Playwright revision - a job used to read "WebKit 2336"
// where the shelf calls the same build 26.5.
const rowSelector = (row) =>
  row.selector || (row.revision == null ? null : String(row.revision));

// A container's job is filed under the revision its image runs, which is never
// the revision the row installs natively - so a Docker job used to fall through
// to the server's label and read "Docker start 1250586" over a row the shelf
// calls Chromium 120.
const dockerSelectorOf = (row) =>
  row.docker
    ? String(
        row.docker.selector != null ? row.docker.selector : row.docker.revision,
      )
    : null;

function jobName(job) {
  const rows = state ? [...state.versions, ...state.extra] : [];
  const wanted = String(job.revision);
  const row =
    rows.find((entry) => rowSelector(entry) === wanted) ||
    (job.kind === 'docker'
      ? rows.find((entry) => dockerSelectorOf(entry) === wanted)
      : null);
  if (!row) return job.label;
  const label = row.label || row.version;
  return label ? `${engineName(row.engine)} ${label}` : `r${row.revision}`;
}

function jobTitle(job, info) {
  if (job.kind === 'doctor') return job.label;
  const name = jobName(job);
  if (info && info.phase === 'open') return name;
  if (info && info.phase === 'ready') return `Starting ${name}`;
  if (job.kind === 'docker') return `Docker · ${name}`;
  // A launch downloads and unpacks first, so both endpoints read as "Installing".
  if (job.kind === 'launch' || job.kind === 'install')
    return `Installing ${name}`;
  return `${capitalise(workWord(job, info))} ${name}`;
}

// The server is the source of truth for what is running, so this survives a reload.
const runningJobFor = (selector) =>
  state.jobs.find(
    (job) => job.kind === 'launch' && String(job.revision) === selector,
  );

// Anything else the server is doing to a version: a download, a delete, a profile
// reset, a Docker container coming up. Launches are excluded because a running
// browser gets a Stop button rather than a label.
const busyJobFor = (selector) =>
  state.jobs.find(
    (job) =>
      job.kind !== 'launch' &&
      job.kind !== 'doctor' &&
      String(job.revision) === selector,
  );

// Dependency installs are jobs too, filed under the component they are fixing.
// Asking the server rather than remembering locally is what keeps the row honest
// across the four-second refresh, which rebuilds these buttons from scratch.
const runningDoctorJob = (component) =>
  state.jobs.find(
    (job) => job.kind === 'doctor' && String(job.revision) === component,
  );

/* ---------- api ---------- */

async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      'X-EngineShelf-Token': TOKEN,
      ...(options.headers || {}),
    },
  });
  if (!response.ok) {
    const detail = await response.json().catch(() => ({}));
    throw new Error(
      detail.error || `${response.status} ${response.statusText}`,
    );
  }
  return response.json();
}

const post = (path, body) =>
  api(path, { method: 'POST', body: JSON.stringify(body) });

// PowerShell's ConvertTo-Json unrolls collections on their way out of a function:
// an empty list can arrive as null and a one-item list as a bare object. Coercing
// the list-shaped fields once, here, beats guarding every use - and stops one odd
// field from taking the whole page down.
const asArray = (value) =>
  Array.isArray(value) ? value : value == null ? [] : [value];

/* ---------- formatting ---------- */

function mb(bytes) {
  if (!bytes) return '0 MB';
  const megabytes = bytes / (1024 * 1024);
  if (megabytes >= 1024) return `${(megabytes / 1024).toFixed(2)} GB`;
  return `${Math.round(megabytes)} MB`;
}

const MONTHS = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

// Split by hand rather than parsed as a Date: "2019-03-19" as a Date is UTC
// midnight, which anywhere west of Greenwich prints as the 18th.
function humanDate(iso) {
  const found = String(iso || '').match(/^(\d{4})-(\d\d)-(\d\d)$/);
  if (!found) return String(iso || '');
  return `${Number(found[3])} ${MONTHS[Number(found[2]) - 1]} ${found[1]}`;
}

function launchOptions() {
  return {
    url: $('url').value.trim(),
    size: $('size').value.trim(),
    gpu: view.gpu === 'auto' ? null : view.gpu === 'on',
  };
}

/* ---------- reading a job's output ----------
   The CLI announces each phase in plain text and lets curl draw the meter, so
   what a job is actually doing is read back out of its log. It cannot come from
   which endpoint started it: a launch downloads and unpacks a missing build
   before any window appears, which is why one used to say "browser open" over a
   download that was still at 30%. */

const CURL_CLOCK = /^(?:\d+:\d\d:\d\d|--:--:--)$/;

// curl's plain meter is twelve columns wide:
//   %Total Total %Recd Recd %Xferd Xferd Dload Upload TimeTotal TimeSpent TimeLeft Speed
function meterFrom(frame) {
  const columns = frame.trim().split(/\s+/);
  if (columns.length !== 12 || !/^\d{1,3}$/.test(columns[0])) return null;
  if (!CURL_CLOCK.test(columns[8]) || !CURL_CLOCK.test(columns[10]))
    return null;
  return {
    percent: Number(columns[0]),
    total: columns[1],
    done: columns[3],
    left: columns[10],
  };
}

// "86.4M" -> bytes. curl writes k/M/G/T suffixes, and nothing for plain bytes.
function curlBytes(text) {
  const found = String(text).match(/^([\d.]+)([kMGT]?)$/);
  if (!found) return null;
  return (
    Number(found[1]) *
    { '': 1, k: 1024, M: 1024 ** 2, G: 1024 ** 3, T: 1024 ** 4 }[found[2]]
  );
}

// "0:00:11" -> "11s left". A dashed clock means curl has nothing to estimate from.
function curlLeft(text) {
  const found = String(text).match(/^(\d+):(\d\d):(\d\d)$/);
  if (!found) return null;
  const seconds =
    Number(found[1]) * 3600 + Number(found[2]) * 60 + Number(found[3]);
  if (!seconds) return null;
  if (seconds < 60) return `${seconds}s left`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60)
    return seconds % 60
      ? `${minutes}m ${seconds % 60}s left`
      : `${minutes}m left`;
  return `${Math.floor(minutes / 60)}h ${minutes % 60}m left`;
}

// Each line the CLI prints to mark a step, latest one wins.
//
// Both of the engine-named lines are built as "<engine display name> <version>"
// - "Downloading Firefox 115.0 (mac, one time only)", "  > WebKit 26.5
// (mac-26-arm64)" - and both patterns here used to spell Chromium. So for three
// of the four engines a download reported no progress at all, and a browser that
// was up never registered as open: its row sat on "Installing..." for as long as
// it ran and never offered Stop. Colours are off whenever stdout is not a tty,
// which is every launch the manager makes, so these match the bare text.
const ENGINE_WORD = Object.values(ENGINE_NAMES).join('|');

const PHASE_MARKS = [
  [new RegExp(`^\\s*Downloading (?:${ENGINE_WORD})\\b`), 'downloading'],
  [/^\s*Extracting\b/, 'extracting'],
  [/\bready\.\s*$/, 'ready'],
  [new RegExp(`^\\s*>\\s+(?:${ENGINE_WORD})\\b`), 'open'],
];

function readJob(output) {
  // Every meter redraw is a carriage-return frame; only the last frame of a line
  // still says anything true.
  const frames = String(output || '')
    .split('\n')
    .map((line) => line.split('\r').pop());

  const info = { phase: null, percent: null, detail: null };
  for (const frame of frames) {
    for (const [pattern, name] of PHASE_MARKS) {
      if (pattern.test(frame)) {
        info.phase = name;
        break;
      }
    }
  }
  if (info.phase !== 'downloading') return info;

  for (let index = frames.length - 1; index >= 0; index--) {
    const meter = meterFrom(frames[index]);
    if (meter) {
      const done = curlBytes(meter.done);
      const total = curlBytes(meter.total);
      info.percent = Math.min(100, meter.percent);
      info.detail =
        [
          done != null && total ? `${mb(done)} / ${mb(total)}` : null,
          curlLeft(meter.left),
        ]
          .filter(Boolean)
          .join(' · ') || null;
      return info;
    }
    // A terminal-style bar - an older CLI, or an install run by hand - still
    // carries a percentage even though it has no byte counts.
    const bar = frames[index].match(/(\d{1,3}(?:\.\d+)?)%\s*$/);
    if (bar) {
      info.percent = Math.min(100, Math.round(Number(bar[1])));
      return info;
    }
  }
  return info;
}

/* ---------- eras ----------
   The shelf is grouped by what a version is *for* rather than by number. Notes in
   catalog.tsv start with the release year, so the grouping follows the catalog
   instead of a table that would go stale as milestones are added. */

const ERAS = [
  {
    id: 'era-1',
    label: '2017 – 2019',
    until: 2019,
  },
  {
    id: 'era-2',
    label: '2020 – 2021',
    until: 2021,
  },
  {
    id: 'era-3',
    label: '2022 – 2023',
    until: 2023,
  },
  {
    id: 'era-4',
    label: '2024 – today',
    until: 9999,
  },
];

// Milestones roughly bracket the same years, and cover rows whose note has no year.
const MILESTONE_YEARS = [
  [76, 2019],
  [95, 2021],
  [120, 2023],
];

function yearOf(row) {
  // Every shelf row carries the year of its release, from the vendor's own
  // index. The rest of this is for builds the shelf does not claim.
  if (Number.isFinite(row.year)) return row.year;
  const stamped = String(row.note || '').match(/^\s*(\d{4})\./);
  if (stamped) return Number(stamped[1]);
  const milestone = Number(row.milestone);
  if (!Number.isFinite(milestone)) return null;
  for (const [ceiling, year] of MILESTONE_YEARS)
    if (milestone <= ceiling) return year;
  return 2024;
}

const eraFor = (row) => {
  const year = yearOf(row);
  return year === null ? null : ERAS.find((era) => year <= era.until);
};

// How much of a changelog fits on a row before the rest goes behind a button.
// A count rather than a measurement: measuring means reading scrollWidth on every
// row of a 288-row list, on every refresh, which is a layout pass the shelf does
// not need to buy.
const NOTE_BRIEF = 64;

// The sticky toolbar's height, read from the stylesheet rather than repeated
// here: the group headings stick directly under it and the era jumps scroll to
// just below it, so all three have to agree on one number.
const TOOLBAR_H =
  parseInt(
    getComputedStyle(document.documentElement).getPropertyValue('--toolbar-h'),
    10,
  ) || 55;

/* ---------- shaping a catalog row for the shelf ---------- */

// The line under the title: the exact build rather than the friendly name. Two
// WebKit releases are both called 26.5 and only the revision says which one this
// is; Edge 151 is really 151.0.4129.107, and that is the string that has to
// match a bug report.
function identOf(engine, row) {
  const ident =
    engine === 'chromium'
      ? row.revision == null
        ? ''
        : `r${row.revision}`
      : engine === 'webkit'
        ? row.id
          ? `r${row.id}`
          : ''
        : row.id || '';
  // The oldest WebKit builds predate any Safari version to map them to, so the
  // shelf calls them r1446 - which is also their exact build. Printing it under
  // a title that already says it read as a stutter.
  return ident === (row.label || '') ? '' : ident;
}

function decorate(row) {
  const engine = row.engine || 'chromium';
  // What to post back when this row is acted on. The server names it; a backend
  // built before there was more than one engine sends only a revision, which for
  // Chromium is exactly what the selector has always been.
  const selector = rowSelector(row);
  const label =
    row.label || (row.milestone != null ? String(row.milestone) : '');
  const version = row.version || row.id || (selector ? `r${selector}` : '?');
  const milestone =
    row.milestone && row.milestone !== '?' ? row.milestone : null;
  // Two notes in the catalog say nothing about the version: one is written when a
   // milestone is added automatically as Chrome ships it, the other when a row is
   // resolved against the live archive. They are about how the row got here, not
   // about what the release brought, and printing them where a changelog goes
   // said "Resolved from the live archive." on seventy rows.
  const BOILERPLATE = [
    'Added automatically as Chrome released it.',
    'Resolved from the live archive.',
    'Installed by revision.',
  ];
  const rawNote = (row.note || '').replace(/^\s*\d{4}\.\s*/, '');
  const raw = BOILERPLATE.includes(rawNote.trim()) ? '' : rawNote;

  // Notes name the features in backticks; those double as the row's tags, so the
  // shelf gains a scannable index without a second column in catalog.tsv.
  const tags = [...raw.matchAll(/`([^`]+)`/g)]
    .map((match) => match[1])
    .slice(0, 3);
  // A curated note where somebody wrote one, and otherwise what the compat data
  // says this version was first to support. Both are "what did this release
  // bring"; the difference is that twenty of them are hand-written and 260 are
  // derived, and the derived ones are why the other 270 rows are no longer blank.
  const feats = featureIndex[`${engine}:${row.id}`] || null;
  const curated = raw.replace(/`/g, '');
  const listed = feats ? feats.names.join(', ') : '';
  const note = curated || listed;
  // What the modal shows: everything, and how much of it was left out. The file
  // ships the most notable fourteen per version rather than all sixty-seven.
  const noteFull = !feats
    ? curated
    : [
        curated,
        `${feats.count} feature${feats.count === 1 ? '' : 's'} first supported here.`,
        feats.names.length < feats.count
          ? `The most notable ${feats.names.length}:`
          : '',
        feats.names.map((name) => `\u2022 ${name}`).join('\n'),
      ]
        .filter(Boolean)
        .join('\n\n');

  // Read off the server's own answer rather than off platformDir, which most of
  // the shelf does not have until a launch resolves it. The server says false
  // here both for a verified Mac-only row and for a milestone old enough that no
  // arm64 build exists - so a row can say Rosetta before anything is downloaded.
  //
  // Which is the same thing as "translated": an x86_64 build on an Apple Silicon
  // machine. Translation is where every failure this shelf knows about lives -
  // the GPU-process crash and the profiler crash are both only there, and the
  // startup abort that kills the oldest Chromium is a 2019 allocator meeting this
  // year's libsystem_malloc, a macOS problem the Linux build in a container does
  // not have. So the container is the recommended route for all of them, and the
  // row says so before anything is downloaded rather than after it went wrong.
  const rosetta = row.native === false;

  // The vendor no longer serves this one: Microsoft's feed keeps about six months
  // of Edge, Playwright deletes the older macOS WebKit archives. Nothing native
  // can be offered for it - not a launch, not even a download - so the row stops
  // pretending otherwise. Absent knowledge this is true, and the row behaves as
  // it always did.
  const nativeGone = row.nativeAvailable === false;

  // Docker is the second way to run the same version, with its own image on
  // disk, its own container and its own profile volume - and the row used to
  // know about none of it, so it said "not installed" over a gigabyte of image
  // and showed nothing at all over a browser that was up. The server reports it
  // under the Linux revision a container actually runs, which is never the
  // revision this host installs natively.
  const dk = row.docker || null;
  const dockerRunning = Boolean(dk && dk.state === 'running');
  const dockerImage = dk ? dk.imageBytes || 0 : 0;
  const dockerAvailable =
    Boolean(dk) && Boolean(state.docker && state.docker.cli);
  // What to post to run or stop the container. Not the same as the revision
  // above: Chromium's container runs a Linux build this host never installs,
  // and WebKit's is addressed by selector.
  const dockerSelector = dk
    ? String(dk.selector != null ? dk.selector : dk.revision)
    : null;

  const launchJob = selector ? runningJobFor(selector) : null;
  // A container's job is filed under the revision its image runs, which is not
  // the row's own - so an image building for a version with no native build here
  // used to leave the row saying nothing at all, still offering to start it.
  const job =
    launchJob ||
    (selector ? busyJobFor(selector) : null) ||
    (dockerSelector && dockerSelector !== selector
      ? busyJobFor(dockerSelector)
      : null);
  const info = (job && jobInfo.get(job.id)) || null;

  // Only the banner the CLI prints at exec time means the browser is up. Until
  // then a launch job is a download, and the row has to say so.
  const open = Boolean(launchJob) && Boolean(info) && info.phase === 'open';
  const busy = open ? null : job;
  const running = open || dockerRunning;

  return {
    raw: row,
    engine,
    selector,
    label,
    version,
    ident: identOf(engine, row),
    date: row.date || '',
    milestone,
    note,
    tags,
    rosetta,
    job,
    info,
    busy,
    running: open, // a native window, which is what Stop acts on
    dockerRunning,
    dockerImage,
    dockerSelector,
    dockerProfileBytes: dk ? dk.profileBytes || 0 : 0,
    dockerStatus: dk ? dk.status || '' : '',
    dockerUrl:
      dockerRunning && dk.port
        ? `http://localhost:${dk.port}/vnc.html?autoconnect=1&resize=scale`
        : null,
    // Offered when this milestone has a Linux build to put in a container. The
    // daemon does not have to be up: the launcher offers to start it, the same
    // way the command line does.
    dockerAvailable,
    // A launch on this machine that got as far as starting and then died. Only
    // the shelf can know it, and only after it happened once - so it comes from
    // the CLI's own record rather than from the catalog.
    knownBad: row.knownBad === true,
    // Nothing here starts natively - the catalog has no build of this version
    // for this machine, or it has one this machine cannot execute, or it has one
    // that has already been watched crash here - and the container runs the
    // Linux build regardless. That makes Docker the row's own button rather than
    // an entry in the menu behind it.
    // If the row recommends the container, the container is the button. Anything
    // else asks someone to read a badge, work out what it means and then reject
    // the button in front of them. The native launcher never goes away - it
    // moves one click, into the menu beside it.
    nativeGone,
    dockerOnly:
      dockerAvailable &&
      (row.supported === false ||
        row.knownBad === true ||
        nativeGone ||
        rosetta),
    name: label ? `${engineName(engine)} ${label}` : version,
    features: feats,
    noteFull,
    installed: Boolean(row.installed),
    // "Is this version taking up disk", which an image answers as much as a
    // downloaded build does. The installed filter and count read this.
    onDisk: Boolean(row.installed) || dockerImage > 0,
    supported: row.supported !== false,
    sizeBytes: row.sizeBytes || 0,
    profileBytes: row.profileBytes || 0,
    diskBytes: (row.sizeBytes || 0) + (row.profileBytes || 0) + dockerImage,
    era: row.extra ? null : eraFor(row),
    status: running
      ? 'running'
      : busy
        ? info && info.phase === 'downloading'
          ? 'downloading'
          : 'working'
        : row.installed || dockerImage
          ? 'installed'
          : 'absent',
    // Typing "firefox", "edge", a year, or a full four-part Edge version all
    // have to find the row, so everything printable about it goes in here.
    search: [
      engineName(engine),
      label,
      version,
      row.id,
      identOf(engine, row),
      row.date,
      raw,
      // Every feature the version was first to support, so "aspect-ratio" finds
      // Chromium 88 and ":has" finds the three that shipped it. This is the whole
      // list, not the handful the row has room to print.
      feats ? feats.names.join(' ') : '',
    ]
      .join(' ')
      .toLowerCase(),
  };
}

/* ---------- dropdowns ---------- */

function buildDropdown(rootId, buttonId, menuId, labelId, options, get, set) {
  const root = $(rootId);
  const menu = $(menuId);

  const close = () => {
    menu.hidden = true;
    root.classList.remove('is-open');
  };

  const paint = () => {
    const current =
      options.find((option) => option.value === get()) || options[0];
    $(labelId).textContent = current.label;
    menu.textContent = '';
    for (const option of options) {
      const item = document.createElement('button');
      item.type = 'button';
      if (option.value === get()) item.className = 'is-on';
      const tick = iconSpan('check');
      tick.className = 'tick';
      item.append(tick, option.label);
      item.onclick = (event) => {
        event.stopPropagation();
        close();
        set(option.value);
        paint();
      };
      menu.append(item);
    }
  };

  $(buttonId).onclick = (event) => {
    event.stopPropagation();
    const wasOpen = !menu.hidden;
    closePopovers();
    if (!wasOpen) {
      menu.hidden = false;
      root.classList.add('is-open');
    }
  };

  paint();
  const handle = { close, paint, isOpen: () => !menu.hidden };
  dropdowns.push(handle);
  return handle;
}

function closePopovers() {
  for (const handle of dropdowns) handle.close();
  if (openMenu) {
    openMenu.remove();
    openMenu = null;
  }
}

const popoverOpen = () =>
  Boolean(openMenu) || dropdowns.some((handle) => handle.isOpen());

document.addEventListener('click', closePopovers);
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') closePopovers();
});

/* ---------- tooltips ----------
   Delegated rather than bound per element: the shelf rebuilds every row on each
   refresh, and 288 rows x two marks is 576 listeners to attach and drop every
   four seconds. Anything carrying data-tip gets one, wherever it is and whenever
   it appears.

   A title attribute was tried first and is what this replaces. It waits about a
   second before appearing, cannot be styled or wrapped, and on a shelf where the
   marks are the only words left, that second is the whole answer. */
let tipFor = null;

function hideTip() {
  if (!tipFor) return;
  tipFor = null;
  const tip = $('tip');
  tip.hidden = true;
  tip.textContent = '';
}

function showTip(target) {
  const text = target.dataset.tip;
  if (!text) return;
  const tip = $('tip');
  tipFor = target;
  tip.textContent = text;
  tip.hidden = false;
  // Measured after it has content, because the width it needs depends on it.
  const box = target.getBoundingClientRect();
  const size = tip.getBoundingClientRect();
  const margin = 8;
  let left = box.left + box.width / 2 - size.width / 2;
  left = Math.max(margin, Math.min(left, window.innerWidth - size.width - margin));
  // Above by preference, below when there is no room - a tooltip half off the top
  // of the window says nothing.
  const above = box.top - size.height - 6;
  tip.style.left = `${Math.round(left)}px`;
  tip.style.top = `${Math.round(above < margin ? box.bottom + 6 : above)}px`;
}

document.addEventListener('mouseover', (event) => {
  const target = event.target.closest && event.target.closest('[data-tip]');
  if (target === tipFor) return;
  hideTip();
  if (target) showTip(target);
});
document.addEventListener('mouseout', (event) => {
  const target = event.target.closest && event.target.closest('[data-tip]');
  if (target && target === tipFor) hideTip();
});
// A tooltip is positioned against the viewport, so anything that moves the thing
// it points at has to take it down rather than leave it hanging in the wrong
// place. The shelf scrolls under the pointer constantly.
window.addEventListener('scroll', hideTip, true);
window.addEventListener('resize', hideTip);
document.addEventListener('click', hideTip);

// Sets the text and takes the accessible name with it: a mark with no words is
// unreadable to a screen reader unless something says what it is.
function tipped(element, text) {
  element.dataset.tip = text;
  element.setAttribute('aria-label', text);
  return element;
}

/* ---------- the two routes ----------
   Every version can be run two ways and a row's job is to say, at a glance, what
   each of them is worth here. Two marks, one per route, each in one of three
   states:

     full colour   this route works, and it is the one to take
     half colour   this route works, but the other one is the better bet
     grey          this route is not available at all

   Drawn as the same glyph twice, the coloured copy clipped to its left half, so
   "half" is a hard vertical split rather than a tint - a tint at 13px is
   indistinguishable from the full colour on a dim screen.

   This replaces four separate badges that each carried a sentence. The sentences
   are still here, in the tooltip. */
function routeMark(glyph, state, kind, text) {
  const wrap = document.createElement('span');
  wrap.className = `route route-${kind}`;
  wrap.dataset.state = state;
  const base = iconSpan(glyph);
  base.className = 'route-base';
  const fill = iconSpan(glyph);
  fill.className = 'route-fill';
  wrap.append(base, fill);
  return tipped(wrap, text);
}

// Why the native route is in the state it is in, and what that means for the
// button. Longest first: a row can be several of these at once and the first one
// true is the one that decides what happens.
function nativeRoute(row) {
  if (!row.supported) {
    return ['off', 'Native: no build of this version exists for this machine.'];
  }
  if (row.nativeGone && !row.installed) {
    return [
      'off',
      row.engine === 'edge'
        ? 'Native: gone. Microsoft\u2019s enterprise feed is the only source ' +
          'for a mac or Windows Edge and it keeps about six months, so there is ' +
          'nothing left to download.'
        : 'Native: gone. Playwright deleted the macOS archive for this build ' +
          'and kept the Linux one, so there is nothing left to download.',
    ];
  }
  if (row.rosetta && rosettaMissing()) {
    return [
      'off',
      'Native: no arm64 build exists this far back and Rosetta 2 is not ' +
        'installed, so nothing here starts natively as this machine is set up.',
    ];
  }
  if (row.knownBad) {
    return [
      'half',
      'Native: it downloads and starts on this machine, then dies in its first ' +
        'second, every time. A copy already on disk still launches from the ' +
        'menu; the container is the route that works.',
    ];
  }
  if (row.rosetta) {
    // Chromium's is the one with a number on it. For the other engines the same
    // translation path is there and no rate has been measured, so this says that
    // rather than borrowing Chromium's figure.
    return [
      'half',
      row.engine === 'chromium'
        ? 'Native: it runs, under Rosetta - and about a third of sessions on a ' +
          'heavy page die there, in a profiler crash no switch turns off. The ' +
          'launcher relaunches and restores the tabs; the container runs the ' +
          'Linux build and has none of it.'
        : 'Native: it runs, under Rosetta - an x86_64 build translated for ' +
          'this machine, with no arm64 build this far back to fall back on. ' +
          'Translation is where every failure this shelf knows about lives, so ' +
          'the container is the route it recommends.',
    ];
  }
  // Every translated build is 'half' above, so this is the untranslated case.
  // The architecture pill is gone from the row, which makes this the only place
  // left that names it - so it names it.
  const arch = platformLabel(row.raw.platformDir);
  return [
    'on',
    arch
      ? `Native: runs on this machine (${arch}).`
      : 'Native: runs on this machine. Which build it comes as is settled ' +
        'against the vendor\u2019s index at launch.',
  ];
}

function dockerRoute(row) {
  if (!row.dockerAvailable) {
    return [
      'off',
      state.docker && state.docker.cli
        ? 'Docker: no container for this version.'
        : 'Docker: not installed on this machine. The container would run the ' +
          'Linux build of this version.',
    ];
  }
  // On or off, never half: a container either exists for this version or it does
  // not, and it runs the same Linux build either way. Which of the two routes to
  // prefer is the native mark's business - saying it twice, once per mark, made
  // the pair look like a comparison of two unrelated things.
  const size = row.dockerImage ? ` Its image is built (${mb(row.dockerImage)}).` : '';
  if (row.dockerRunning) {
    return ['on', `Docker: running. The desktop is a click away.${size}`];
  }
  if (row.dockerOnly) {
    return [
      'on',
      'Docker: runs the Linux build of this version, which is the route that ' +
        `works here.${size}`,
    ];
  }
  return [
    'on',
    'Docker: runs the Linux build of this version in a container with its own ' +
      `desktop.${size}`,
  ];
}

/* ---------- system check ---------- */

let doctorPinned = false; // shown because the user asked, not because of a fault
let doctorDismissed = false; // hidden because the user asked, faults and all

const STATUS_WORD = {
  ok: 'ok',
  missing: 'missing',
  inactive: 'not running',
  na: 'not needed',
};

const doctorProblems = () => {
  const report = state && state.doctor;
  if (!report || !report.components) return [];
  // "na" means this machine does not need it, so it is not something to act on.
  return report.components.filter(
    (c) => c.status === 'missing' || c.status === 'inactive',
  );
};

// Rosetta 2 is what translates the x86_64 builds on Apple Silicon, and without
// it those milestones do not start at all - "bad CPU type in executable" rather
// than a slow browser. The shelf reads it because for those rows the container
// stops being a preference and becomes the only way to run the version.
const rosettaMissing = () => {
  const report = state && state.doctor;
  if (!report || !report.components) return false;
  const found = report.components.find((c) => c.id === 'rosetta');
  return Boolean(found) && found.status === 'missing';
};

// Only what EngineShelf cannot work without. The recommended and optional ones
// are worth knowing about, but not worth a panel in front of the shelf on every
// launch - the header button carries the count for those.
const doctorBlockers = () =>
  doctorProblems().filter((c) => c.need === 'required');

const doctorVisible = () =>
  doctorPinned || (doctorBlockers().length > 0 && !doctorDismissed);

function renderDoctor() {
  const panel = $('doctor');
  const report = state && state.doctor;
  const problems = doctorProblems();

  const blockers = doctorBlockers();
  const button = $('check-btn');
  button.classList.toggle(
    'has-problem',
    problems.length > 0 && blockers.length === 0,
  );
  button.classList.toggle('has-blocker', blockers.length > 0);
  button.classList.toggle('is-on', doctorVisible());
  button.querySelector('[data-icon]').innerHTML = icon(
    problems.length ? 'warn' : 'ok',
  );
  $('check-label').textContent = problems.length
    ? `${problems.length} check${problems.length > 1 ? 's' : ''}`
    : 'System check';

  if (!report || !report.components.length || !doctorVisible()) {
    panel.hidden = true;
    return;
  }

  panel.hidden = false;
  panel.textContent = '';

  const head = document.createElement('div');
  head.className = 'doctor-head';
  const heading = document.createElement('h2');
  heading.textContent = 'System check';
  const note = document.createElement('span');
  note.className = 'muted';
  note.textContent = blockers.length
    ? `${blockers.length} thing${blockers.length > 1 ? 's' : ''} EngineShelf cannot work without.`
    : problems.length
      ? `Everything required is present. ${problems.length} optional thing${problems.length > 1 ? 's' : ''} you could still sort out.`
      : 'Everything EngineShelf needs is present.';
  const hide = document.createElement('button');
  hide.className = 'btn';
  hide.textContent = 'Hide';
  hide.onclick = () => {
    doctorPinned = false;
    doctorDismissed = true;
    renderDoctor();
  };
  head.append(heading, note, hide);
  panel.append(head);

  const body = document.createElement('div');
  body.style.display = 'flex';
  body.style.flexDirection = 'column';
  body.style.gap = '6px';

  // When nothing is wrong the pinned panel lists everything, so the user can see
  // what was actually checked rather than an unexplained "all good".
  const rows = problems.length && !doctorPinned ? problems : report.components;
  for (const component of rows) body.append(doctorRow(component));
  panel.append(body);
}

function doctorRow(component) {
  const row = document.createElement('div');
  row.className = 'doctor-row';
  const kind =
    component.status === 'ok' || component.status === 'na' ? 'ok' : 'warn';
  const mark = iconSpan(kind === 'ok' ? 'ok' : 'warn');
  mark.style.color = kind === 'ok' ? 'var(--c-ok)' : 'var(--c-warn)';

  const name = document.createElement('span');
  name.className = 'name';
  name.textContent = component.label;

  const pill = document.createElement('span');
  pill.className = `pill ${component.status}`;
  pill.textContent = STATUS_WORD[component.status] || component.status;

  const why = document.createElement('span');
  why.className = 'why';
  why.textContent = component.why;

  row.append(mark, name, pill, why);

  const actionable =
    component.status === 'missing' || component.status === 'inactive';
  if (actionable && component.fix) {
    const command = document.createElement('code');
    command.className = 'cmd';
    command.textContent = component.fix;
    why.append(command);

    const starting = component.status === 'inactive';
    const busy = runningDoctorJob(component.id);
    const button = document.createElement('button');
    button.className = 'btn';
    button.title = component.note || component.fix;

    if (busy) {
      // Not a dead end and not a lie: it says what is happening, and clicking it
      // brings the log back up if the panel was closed.
      button.textContent = starting ? 'Starting…' : 'Installing…';
      button.onclick = () =>
        watch(busy.id, `${component.label} — ${component.fix}`);
      row.classList.add('busy');
    } else {
      button.classList.add('accent');
      button.textContent = starting ? 'Start it' : 'Install';
      button.onclick = async () => {
        button.disabled = true;
        try {
          const { job } = await post('/api/doctor-install', {
            component: component.id,
          });
          watch(job, `${component.label} — ${component.fix}`);
        } catch (error) {
          // A refused install used to leave a dead button and no explanation.
          showJobFailure(
            `${component.label} — ${component.fix}`,
            error.message,
          );
          button.disabled = false;
          return;
        }
        refresh();
      };
    }
    row.append(button);
  } else if (actionable) {
    // No command means this platform has no automatic route; say so rather than
    // offering a button that cannot work.
    const hint = document.createElement('span');
    hint.className = 'pill';
    hint.textContent = 'install manually';
    row.append(hint);
  }
  return row;
}

$('check-btn').onclick = () => {
  const visible = doctorVisible();
  doctorPinned = !visible;
  doctorDismissed = visible;
  renderDoctor();
};

/* ---------- whole-list stand-ins ---------- */

function showState({
  glyph = 'empty',
  tone = '',
  title,
  detail,
  actionLabel,
  onAction,
}) {
  const block = document.createElement('div');
  block.className = `state-block${tone ? ` ${tone}` : ''}`;
  block.innerHTML = icon(glyph);

  const heading = document.createElement('h2');
  heading.textContent = title;
  const text = document.createElement('p');
  text.textContent = detail;
  block.append(heading, text);

  if (actionLabel && onAction) {
    const button = document.createElement('button');
    button.className = 'btn accent';
    button.textContent = actionLabel;
    button.onclick = onAction;
    block.append(button);
  }

  const list = $('list');
  list.setAttribute('aria-busy', 'false');
  list.textContent = '';
  list.append(block);
  // An error is an answer too: the shimmer would go on promising a shelf that
  // is not coming.
  bootingDone();
}

/* ---------- the first second ----------
   Reading the shelf means reading the catalog, the builds directory, the
   profile sizes and whatever Docker has to say, and none of that is instant on
   a cold start. The page used to spend that second as an empty shell: no rows,
   no engines, and a disk card reading 0 MB - which is not "not known yet", it
   is a claim, and a wrong one. So the shape of the answer is drawn first, with
   the parts that are known already (the four engines have names before any
   server says so) and a shimmer where a number will be. */

function skeletonBlock(className) {
  const block = document.createElement('span');
  block.className = `sk ${className}`;
  return block;
}

function drawSkeleton() {
  const list = $('list');
  list.textContent = '';
  // Eight rows is about a screenful; fewer reads as a short shelf, more as a
  // page that has finished loading something wrong.
  for (let index = 0; index < 8; index++) {
    const row = document.createElement('article');
    row.className = 'row skeleton';
    row.append(skeletonBlock('sk-dot'), skeletonBlock('sk-mark'));
    const body = document.createElement('div');
    body.className = 'sk-body';
    body.append(skeletonBlock('sk-title'), skeletonBlock('sk-note'));
    row.append(body, skeletonBlock('sk-btn'));
    list.append(row);
  }

  // The engines are known from the page itself, so these are real names with a
  // shimmer where the count goes - not a row of grey bars.
  const engines = $('engine-list');
  engines.textContent = '';
  const line = (glyph, name) => {
    const item = document.createElement('div');
    item.className = 'side-btn is-quiet';
    item.append(glyph ? engineMark(glyph) : iconSpan('grid'));
    item.append(spanWith('side-label', name));
    item.append(skeletonBlock('sk-count'));
    engines.append(item);
  };
  line(null, 'All engines');
  for (const engine of ENGINE_ORDER) line(engine, engineName(engine));

  $('summary').textContent = 'Reading the shelf…';
}

/* Off once there is something real on the page. Everything the booting class
   softens - the counts, the disk figures - has its own value by then. */
function bootingDone() {
  document.body.classList.remove('booting');
}

/* ---------- rendering ---------- */

function render() {
  const rows = [...state.versions, ...state.extra].map(decorate);
  // What the engine filter lets through. The shelf counts, the era jumps and the
  // summary all describe this rather than the whole shelf - with Firefox picked,
  // "5 installed" above a single visible Firefox build is just wrong.
  const scoped =
    view.engine === 'all'
      ? rows
      : rows.filter((row) => row.engine === view.engine);

  const counts = {
    all: scoped.length,
    // A built Docker image is a copy of that version taking up disk, so it
    // counts as installed here even with nothing in the builds directory.
    installed: scoped.filter((row) => row.onDisk).length,
    running: scoped.filter((row) => row.status === 'running').length,
  };

  renderChrome(rows, scoped, counts);
  renderDoctor();
  renderStatusBar();
  renderLogTabs();

  $('list').hidden = false;

  const query = view.query.trim().toLowerCase();
  const visible = scoped.filter((row) => {
    if (view.filter === 'installed' && !row.onDisk) return false;
    if (view.filter === 'running' && row.status !== 'running') return false;
    return !query || row.search.includes(query);
  });

  const of =
    view.engine === 'all'
      ? `${scoped.length} versions`
      : `${scoped.length} ${engineName(view.engine)} versions`;
  $('summary').textContent =
    `${visible.length} of ${of} · ${counts.installed} installed · ${counts.running} running`;

  const list = $('list');
  list.setAttribute('aria-busy', 'false');
  list.textContent = '';

  if (!rows.length) {
    showState({
      glyph: 'warn',
      title: 'No versions in the catalog',
      detail:
        'catalog.tsv is missing or empty. Rebuild it from the Chromium ' +
        'archive with:  python3 tools/refresh-catalog.py',
    });
    return;
  }

  if (!visible.length) {
    showState({
      glyph: 'search',
      title: 'Nothing matches that filter',
      detail:
        view.filter === 'installed'
          ? 'No browser has been downloaded into this profile directory yet, and no ' +
            'Docker image has been built either.'
          : 'No version on the shelf matches the current engine, filter and search.',
      actionLabel: 'Reset filters',
      onAction: () => {
        view.filter = 'all';
        view.engine = 'all';
        view.query = '';
        $('query').value = '';
        render();
      },
    });
    return;
  }

  for (const group of groupRows(visible)) list.append(renderGroup(group));
  lastPaint = paintSignature();
  setCloseGuard();
}

// In the list, the engines are a filter: four engines share one shelf and most
// of the time you want one of them. Counted over the whole shelf rather than the
// filtered view, so the row you would click to widen the filter still says how
// much widening it would show.
function renderEngineFilters(rows) {
  const host = $('engine-list');
  host.textContent = '';

  const pick = (engine, glyph, name) => {
    const mine =
      engine === 'all' ? rows : rows.filter((r) => r.engine === engine);
    if (!mine.length) return;
    const on = mine.filter((row) => row.onDisk).length;
    const button = document.createElement('button');
    button.className = `side-btn${view.engine === engine ? ' is-on' : ''}`;
    button.append(glyph ? engineMark(engine) : iconSpan('grid'));
    button.append(spanWith('side-label', name));
    const tally = spanWith(
      'count mono',
      on ? `${on}/${mine.length}` : `${mine.length}`,
    );
    button.append(tally);
    button.title = on
      ? `${on} of ${mine.length} ${name} versions on disk`
      : `${mine.length} ${name} versions on the shelf, none downloaded`;
    button.onclick = () => {
      view.engine = engine;
      render();
    };
    host.append(button);
  };

  pick('all', false, 'All engines');
  for (const engine of ENGINE_ORDER) pick(engine, true, engineName(engine));
}

function spanWith(className, text) {
  const span = document.createElement('span');
  span.className = className;
  if (text) span.textContent = text;
  return span;
}

// Header, sidebar and the disk read-outs: everything outside the shelf itself.
// `rows` is the whole shelf, `scoped` only the engine being looked at - the disk
// gauge describes the machine, the counts and the era jumps describe the view.
function renderChrome(rows, scoped, counts) {
  $('host').textContent =
    `${state.os}/${state.arch} · ${state.hostPlatforms[0] || '?'}`;
  $('foot-path').textContent = `Files in ${state.root}`;

  // From the server, which walks the whole builds directory. Summing the rows
  // below instead only ever saw Chromium, and under-reported a 2.2 GB directory
  // as 589 MB once Firefox, Edge and WebKit could live there too.
  //
  // Falls back to that row sum when the field is absent: this page is served by
  // two independent backends, and a Windows manager built before the field
  // existed should show a slightly low number rather than a zero.
  const hasTotals = typeof state.browserBytes === 'number';
  const browsers = hasTotals
    ? state.browserBytes
    : rows.reduce((total, row) => total + row.sizeBytes, 0);
  const profiles = hasTotals
    ? state.profileBytes
    : rows.reduce((total, row) => total + row.profileBytes, 0);
  // Images and their profile volumes live inside Docker rather than under the
  // EngineShelf directory, so nothing that walks the file tree can see them -
  // and at a gigabyte each they were the largest thing this gauge left out.
  const containers = state.dockerBytes || 0;
  const total = browsers + profiles + containers;
  const share = (value) => `${total ? (value / total) * 100 : 0}%`;

  $('disk-text').textContent = mb(total);
  $('gauge').title = containers
    ? `${mb(browsers)} of browsers, ${mb(profiles)} of profiles and ${mb(containers)} of Docker images`
    : `${mb(browsers)} of browsers and ${mb(profiles)} of profiles on disk`;
  for (const [id, value] of [
    ['browsers', browsers],
    ['profiles', profiles],
    ['docker', containers],
  ]) {
    $(`disk-seg-${id}`).style.width = share(value);
    $(`card-seg-${id}`).style.width = share(value);
  }
  $('disk-browsers').textContent = mb(browsers);
  $('disk-profiles').textContent = mb(profiles);
  $('disk-docker').textContent = mb(containers);
  // Hidden rather than shown as zero: most machines never build an image, and a
  // permanent "Docker 0 MB" line would be noise on all of them.
  $('disk-docker-line').hidden = containers === 0;

  for (const button of document.querySelectorAll('[data-filter]')) {
    button.classList.toggle('is-on', button.dataset.filter === view.filter);
  }
  for (const slot of document.querySelectorAll('[data-count]')) {
    slot.textContent = counts[slot.dataset.count];
  }
  // Which engines are on the shelf, and how much of each is here.
  $('engines-group').hidden = false;
  renderEngineFilters(rows);

  const eras = $('eras');
  eras.textContent = '';
  for (const era of view.sort === 'new' ? [...ERAS].reverse() : ERAS) {
    const count = scoped.filter((row) => row.era === era).length;
    if (!count) continue;
    const button = document.createElement('button');
    button.className = 'era-btn';
    const label = document.createElement('span');
    label.textContent = era.label;
    const tally = document.createElement('span');
    tally.className = 'count mono';
    tally.textContent = count;
    button.append(label, tally);
    button.onclick = () => {
      const section = document.getElementById(era.id);
      // Landing under the sticky toolbar rather than behind it. 48 was a guess
      // made when nothing was sticky except the toolbar; the heading sticks
      // there too now, so the number has to be the toolbar's own height.
      if (section)
        $('main').scrollTo({
          top: section.offsetTop - TOOLBAR_H,
          behavior: 'smooth',
        });
    };
    eras.append(button);
  }
  // Sorting by disk collapses the eras into one group, so the jump list would
  // point at sections that are no longer on the page.
  $('eras-group').hidden = !eras.childElementCount || view.sort === 'disk';
}

function groupRows(visible) {
  // Newest first. Sorting by version number worked while the shelf was one
  // engine; across four it is meaningless - Chromium 120, Firefox 121, Edge 120
  // and WebKit 17.4 are contemporaries. The release date is the one ordering
  // they share, and it puts contemporaries next to each other, which is the
  // whole reason to have them on one shelf. Same-day releases fall back to the
  // engine order so the four never shuffle between refreshes.
  const byDate = (a, b) =>
    (a.date < b.date ? 1 : a.date > b.date ? -1 : 0) ||
    ENGINE_ORDER.indexOf(a.engine) - ENGINE_ORDER.indexOf(b.engine) ||
    (Number(b.milestone) || 0) - (Number(a.milestone) || 0);
  const sorted = (rows) => {
    if (view.sort === 'old') return rows.slice().sort((a, b) => -byDate(a, b));
    if (view.sort === 'disk')
      return rows.slice().sort((a, b) => b.diskBytes - a.diskBytes);
    return rows.slice().sort(byDate);
  };

  if (view.sort === 'disk') {
    return [
      {
        id: 'by-disk',
        label: 'By disk used',
        rows: sorted(visible),
      },
    ];
  }

  const groups = ERAS.map((era) => ({
    id: era.id,
    label: era.label,
    rows: sorted(visible.filter((row) => row.era === era)),
  })).filter((group) => group.rows.length);
  // Oldest era first reads as a timeline and matches the jump list; newest-first
  // has to turn both around, which is what this used to get backwards.
  if (view.sort === 'new') groups.reverse();

  // Builds installed by raw revision, and anything the catalog cannot date.
  const loose = visible.filter((row) => !row.era);
  if (loose.length) {
    groups.unshift({
      id: 'loose',
      label: 'Added by revision',
      rows: sorted(loose),
    });
  }
  return groups;
}

function renderGroup(group) {
  const section = document.createElement('section');
  section.id = group.id;

  // Sticks to the top of the shelf for as long as its own rows are on screen,
  // then the next one takes over - the way a phone gallery keeps the month in
  // view. Which is also why the era's one-line description is gone: a caption
  // reads once, and this line is now on screen the whole time you are inside it.
  const head = document.createElement('div');
  head.className = 'group-head';
  const heading = document.createElement('h2');
  heading.textContent = group.label;
  const rule = document.createElement('span');
  rule.className = 'rule';
  head.append(heading, rule);

  const body = document.createElement('div');
  body.className = 'group-rows';
  for (const row of group.rows) body.append(renderRow(row));

  section.append(head, body);
  return section;
}

function renderRow(row) {
  const node = $('row-template').content.firstElementChild.cloneNode(true);

  // Which engine, before which version. Four engines on one shelf and the only
  // thing telling them apart used to be the word in the title.
  node.querySelector('[data-engine]').replaceWith(engineMark(row.engine));
  node.querySelector('[data-title]').textContent = row.name;
  // Chromium is the one engine whose shelf name and whose real version are
  // different things - milestone 74 is 74.0.3729.0 - and that version used to sit
  // alone in the right-hand column. It reads here, under the name, where the
  // other three engines have always had theirs. The snapshot revision is the
  // string a bug report has to match, so it moves into the tooltip rather than
  // off the row.
  const idLine = node.querySelector('[data-rev]');
  if (row.engine === 'chromium' && row.version && row.version !== row.label) {
    idLine.textContent = row.version;
    if (row.ident) tipped(idLine, `Snapshot revision ${row.ident}`);
  } else {
    idLine.textContent = row.ident;
  }
  // The changelog, short enough to sit on one line, with a button to open the
  // rest when there is more. "N/A" rather than a blank when there is none: a
  // blank line looks like something failed to load, and most of the shelf has no
  // changelog because nobody wrote one, which is a fact rather than a fault.
  const noteLine = node.querySelector('[data-note]');
  const brief =
    row.note.length > NOTE_BRIEF
      ? `${row.note.slice(0, NOTE_BRIEF).replace(/[\s,]+$/, '')}\u2026`
      : row.note;
  if (!row.note) {
    noteLine.textContent = 'N/A';
    noteLine.classList.add('is-empty');
  } else {
    noteLine.textContent = `${brief} `;
    // Offered whenever there is more behind it than the line shows - either the
    // line was cut, or the file holds more names than the line could ever fit.
    const hidden =
      brief !== row.note ||
      (row.features && row.features.count > row.features.names.length);
    if (hidden) {
      const more = document.createElement('button');
      more.type = 'button';
      more.className = 'note-more';
      more.append(iconSpan('expand'));
      tipped(more, 'What this version brought, in full');
      more.onclick = () => {
        $('note-title').textContent = row.name;
        $('note-text').textContent = row.noteFull;
        $('note-dialog').showModal();
      };
      noteLine.append(more);
    }
  }

  const dot = node.querySelector('[data-dot]');
  dot.dataset.state = row.status;
  dot.title = row.running
    ? 'Running'
    : row.dockerRunning
      ? `Running in Docker — ${row.dockerStatus || 'container up'}`
      : row.busy
        ? row.busy.label
        : row.installed
          ? 'Installed'
          : row.dockerImage
            ? 'Docker image built, not running'
            : 'Not installed';

  const tags = node.querySelector('[data-tags]');

  // When it shipped, first, because that is what a row gets picked by: nobody
  // hunts for "Chromium 88", they hunt for "something from early 2021". The
  // feature pills that used to sit here are gone - they were lifted out of the
  // note printed directly above them and said it twice.
  if (row.date) {
    const when = document.createElement('span');
    when.className = 'tag tag-date';
    when.append(iconSpan('calendar'), humanDate(row.date));
    tags.append(when);
  }

  // No architecture pill. It was the last text badge on the row and it repeated
  // what the native mark already carries: the mark is half when a build is
  // translated and full when it is not, and its tooltip names the architecture
  // either way. A row's words are its name, its note and its button.
  const routes = document.createElement('span');
  routes.className = 'routes';
  const [nativeState, nativeWhy] = nativeRoute(row);
  const [dockerState, dockerWhy] = dockerRoute(row);
  routes.append(
    routeMark('desktop', nativeState, 'native', nativeWhy),
    routeMark('cube', dockerState, 'docker', dockerWhy),
  );
  tags.append(routes);

  // No "Docker · running" tag. The row already says a container is up - its own
  // button is Stop - and the way back to the noVNC desktop is the first entry in
  // the menu beside it, which is where a control belongs.

  // Two copies of one version, one line each, right-aligned and stacked: the
  // native build on top and the container image under it. What used to be on the
  // top line was the version, which only Chromium ever had a different one of -
  // it reads under the name now, where the other three engines have always put
  // theirs.
  const sizeLine = (element, glyph, text) => {
    element.textContent = '';
    element.hidden = !text;
    if (!text) return;
    element.append(iconSpan(glyph), text);
  };
  sizeLine(
    node.querySelector('[data-size]'),
    'desktop',
    row.busy
      ? `${workWord(row.busy, row.info)}…`
      : row.installed
        ? `${mb(row.sizeBytes)} · ${mb(row.profileBytes)} profile`
        : '',
  );
  sizeLine(
    node.querySelector('[data-size-docker]'),
    'cube',
    row.dockerImage
      ? `${mb(row.dockerImage)}` +
        (row.dockerProfileBytes ? ` · ${mb(row.dockerProfileBytes)} profile` : '')
      : '',
  );

  if (row.busy) {
    // Determinate while curl is reporting, a moving stripe for the steps that
    // cannot be measured - unpacking, deleting, waiting on Docker.
    const bar = node.querySelector('[data-progress]');
    const percent = row.info ? row.info.percent : null;
    bar.hidden = false;
    if (percent == null) bar.classList.add('indeterminate');
    else node.querySelector('[data-progress-bar]').style.width = `${percent}%`;
  }

  // Dimmed only when there is nothing to be done with the row at all. A version
  // with no build for this machine still runs in a container, so it keeps its
  // buttons - it was the greyed-out rows with no way to open them that made the
  // whole shelf look shorter than it is.
  if (!row.supported && !row.dockerOnly) {
    node.classList.add('unsupported');
  } else {
    if (!row.supported) node.classList.add('docker-only');
    if (row.running || row.dockerRunning) node.classList.add('is-running');
    renderActions(node.querySelector('[data-actions]'), row);
  }
  return node;
}

function renderActions(container, row) {
  const selector = row.selector;
  const action = document.createElement('button');
  action.className = 'btn';

  if (row.busy) {
    // A download in progress used to leave this saying "Install & launch", which
    // invited a second one while the first was still running.
    const percent = row.info ? row.info.percent : null;
    const word = workWord(row.busy, row.info);
    if (stopping.has(row.busy.id)) {
      // SIGTERM reaches curl a moment before the job ends, and a button still
      // offering to cancel invited a second press at exactly the wrong time.
      action.append(iconSpan('clock'), 'Cancelling…');
      action.disabled = true;
      action.title = 'Waiting for this to stop';
    } else if (row.status === 'downloading' && percent != null) {
      action.append(iconSpan('down-circle'), `${percent}%`);
      action.title = 'Show what this is doing';
      action.onclick = () => watch(row.busy.id, jobName(row.busy));
    } else {
      action.append(
        iconSpan(row.status === 'downloading' ? 'down-circle' : 'clock'),
        `${capitalise(word)}…`,
      );
      action.title = 'Show what this is doing';
      action.onclick = () => watch(row.busy.id, jobName(row.busy));
    }
  } else if (row.running) {
    // A disabled "Running" button is a dead end; closing the window is the other
    // way out, but the button is right here.
    const jobId = row.job.id;
    if (stopping.has(jobId)) {
      // SIGTERM to the process group takes a moment to bring the window down,
      // and a button still reading "Stop" invited a second press.
      action.append(iconSpan('clock'), 'Stopping…');
      action.disabled = true;
      action.title = 'Waiting for the browser to close';
    } else {
      action.classList.add('warn');
      action.append(iconSpan('stop'), 'Stop');
      action.title = 'Close this browser and everything it started';
      action.onclick = () => cancelJob(jobId, `Stopping ${row.name}`);
    }
  } else if (row.dockerRunning) {
    // The container is up, so the version is running even though no native
    // window is - and something is burning CPU that the row has to be able to
    // turn off. "Open the desktop" in the menu beside this is the way back to it.
    action.classList.add('warn');
    action.append(iconSpan('stop'), 'Stop');
    action.title = 'Stop the Docker container running this version';
    action.onclick = async () => {
      action.disabled = true;
      try {
        const { job } = await post('/api/docker', {
          selector: row.dockerSelector,
          action: 'stop',
        });
        watch(job, `Stopping Docker · ${row.name}`);
      } catch (error) {
        showJobFailure(`Stopping Docker · ${row.name}`, error.message);
        action.disabled = false;
        return;
      }
      refresh();
    };
  } else if (row.dockerOnly) {
    // Here the container is not a fallback, it is the only way this version
    // runs on this machine - so it is the button, not something to be found in
    // the menu behind it. Ahead of "installed" deliberately: a build that is on
    // disk but cannot execute here is still not something to launch.
    // Two ways to run a version, and each has the same three states, so each
    // gets the same three buttons:
    //
    //   nothing on disk   Get                    Get & launch in Docker
    //   on disk           Launch                 Launch in Docker
    //   fetch only (menu) Download only          Get the container only
    //
    // Including the colour. Accent means "this runs now"; a row with no image
    // has a multi-minute build in front of it and must not wear it, any more
    // than an undownloaded native row wears it on Get.
    if (row.dockerImage) action.classList.add('accent');
    // Same words as the native button, and the cube carries the difference. The
    // pair used to read "Get" against "Get & launch in Docker" - one button four
    // times the width of the other, on rows sitting directly above each other.
    action.append(iconSpan('cube'), row.dockerImage ? 'Launch' : 'Get');
    let why;
    if (!row.supported) {
      why = 'No build of this version exists for this machine.';
    } else if (row.nativeGone && !row.installed) {
      why =
        'The vendor no longer serves this version for this machine, so there ' +
        'is nothing left to download.';
    } else if (row.knownBad) {
      why = 'The native build starts on this machine and dies before its window.';
    } else if (rosettaMissing()) {
      why = 'No arm64 build exists this far back and Rosetta 2 is not installed.';
    } else {
      why =
        'The native build of this one crashes often enough that the container ' +
        'is the better route.';
    }
    action.title =
      why +
      (row.dockerImage
        ? ' Docker runs its container and opens the desktop.'
        : ' Docker builds its image first - several minutes, once - then runs ' +
          'it and opens the desktop.') +
      (row.supported ? ' The menu beside this button still launches natively.' : '');
    action.onclick = () => startDocker(action, row);
  } else if (row.installed) {
    action.classList.add('accent');
    action.append(iconSpan('play'), 'Launch');
    action.title = 'Open this build';
    action.onclick = () => start(action, row);
  } else if (row.dockerImage) {
    // The image is already built, so this is one click and no download - the
    // same shape as Launch, which is what it is.
    action.classList.add('accent');
    action.append(iconSpan('cube'), 'Launch');
    action.title =
      'Run this version in its Docker container and open the desktop';
    action.onclick = () => startDocker(action, row);
  } else {
    action.append(iconSpan('download'), 'Get');
    action.title = 'Download this build and launch it';
    action.onclick = () => start(action, row);
  }
  container.append(action);

  // A download is minutes of network and an image build is longer, and until
  // now the only way out of either was to quit the manager. Deletes and profile
  // resets are deliberately not offered: they are over in a moment, and half a
  // deleted directory is worse than waiting for it.
  if (
    row.busy &&
    CANCELLABLE.has(row.busy.kind) &&
    !stopping.has(row.busy.id)
  ) {
    const jobId = row.busy.id;
    const cancel = document.createElement('button');
    cancel.className = 'btn icon-btn warn';
    cancel.append(iconSpan('x'));
    cancel.title =
      row.busy.kind === 'docker'
        ? 'Cancel this Docker build'
        : row.status === 'downloading'
          ? 'Cancel this download'
          : 'Cancel this install';
    cancel.onclick = (event) => {
      event.stopPropagation();
      cancelJob(jobId, `Cancelling ${row.name}`);
    };
    container.append(cancel);
  }

  const more = document.createElement('button');
  more.className = 'btn icon-btn';
  more.append(iconSpan('dots'));
  more.title = 'More actions';
  more.onclick = (event) => {
    event.stopPropagation();
    toggleMenu(container, row);
  };
  container.append(more);
}

async function start(button, row) {
  button.disabled = true;
  try {
    const { job } = await post('/api/launch', {
      selector: row.selector,
      ...launchOptions(),
    });
    watch(job, row.name);
  } catch (error) {
    showJobFailure(row.name, error.message);
    button.disabled = false;
    return;
  }
  refresh();
}

// The launch options above are for the native launcher - a container brings up a
// whole desktop and takes none of them - so this is deliberately its own path
// rather than a flag on start().
async function startDocker(button, row) {
  return startDockerBy(button, row.dockerSelector, row.name);
}

// Keyed by selector rather than by the row object, because the caller that
// starts a container does not always have one - the row menu passes a selector it
// read off the row minutes earlier.
async function startDockerBy(button, selector, name) {
  button.disabled = true;
  try {
    const { job } = await post('/api/docker', { selector, action: 'start' });
    watch(job, `Docker · ${name}`);
  } catch (error) {
    showJobFailure(`Docker · ${name}`, error.message);
    button.disabled = false;
    return;
  }
  refresh();
}

// Cancelling a download and stopping a running browser are the same request -
// SIGTERM to the job's process group - so what differs is only what the row says
// while it happens. `title` carries that word into the log panel if it fails.
async function cancelJob(jobId, title) {
  stopping.add(jobId);
  render();
  renderLogTabs();
  try {
    await post('/api/stop', { job: jobId });
  } catch (error) {
    stopping.delete(jobId);
    showJobFailure(title, error.message);
    return;
  }
  setTimeout(refresh, 400);
}

function toggleMenu(container, row) {
  if (openMenu) {
    const wasSame = openMenu.parentElement === container;
    closePopovers();
    if (wasSame) return;
  } else {
    closePopovers();
  }

  const selector = row.selector;
  const menu = document.createElement('div');
  menu.className = 'menu';

  const item = (glyph, label, handler, danger = false) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.append(iconSpan(glyph), label);
    if (danger) button.className = 'danger';
    button.onclick = async () => {
      closePopovers();
      await handler();
      refresh();
    };
    menu.append(button);
  };

  // Nothing to download when the catalog has no build of this version for this
  // machine, or when the vendor has stopped serving the one it has: the entry
  // used to be there and the job it started died in the log.
  if (!row.installed && row.supported && !row.nativeGone) {
    item('download', 'Download only', async () => {
      const { job } = await post('/api/install', { selector });
      watch(job, `Installing ${row.name}`);
    });
  }

  // Docker, if this milestone has a Linux build to put in a container. Every
  // action is keyed by that Linux revision, which is the mismatch that used to
  // leave a running container looking stopped: the shelf compared it against the
  // revision this host installs natively, and the two are never the same.
  const docker = row.dockerSelector;
  if (row.dockerAvailable) {
    if (row.dockerRunning) {
      if (row.dockerUrl) {
        item('link', 'Open the desktop', async () => {
          window.open(row.dockerUrl, '_blank', 'noopener');
        });
      }
      item('stop', 'Stop the container', async () => {
        const { job } = await post('/api/docker', {
          selector: docker,
          action: 'stop',
        });
        watch(job, `Stopping Docker · ${row.name}`);
      });
      if (row.installed) {
        // Both ways of running this version are available and only one of them
        // has the row's button, so the other cannot be a dead end.
        item('play', 'Launch natively as well', async () => {
          const { job } = await post('/api/launch', {
            selector,
            ...launchOptions(),
          });
          watch(job, row.name);
        });
      }
    } else {
      // Not when the row's own button already is this: on a Docker-first row the
      // two read word for word the same, which is one entry too many.
      if (!row.dockerOnly) {
        item(
          'cube',
          row.dockerImage
            ? 'Launch in Docker (noVNC)'
            : 'Get & launch in Docker',
          async () => {
            const { job } = await post('/api/docker', {
              selector: docker,
              action: 'start',
            });
            watch(job, `Docker · ${row.name}`);
          },
        );
      }
      // The other half of "Download only": fill the shelf now, use it later. An
      // image build is minutes, and having to sit through them at the moment
      // you wanted a browser is the thing this avoids.
      if (!row.dockerImage) {
        item('download', 'Get the container only', async () => {
          const { job } = await post('/api/docker', {
            selector: docker,
            action: 'build',
          });
          watch(job, `Building Docker image · ${row.name}`);
        });
      }
    }
    if (row.dockerImage) {
      const held = row.dockerImage + row.dockerProfileBytes;
      item(
        'trash',
        `Delete Docker image (${mb(row.dockerImage)})`,
        async () => {
          const go = await askConfirm({
            title: `Delete the Docker image for ${row.name}?`,
            body:
              `Frees up to ${mb(held)}, less whatever layers other EngineShelf images ` +
              "share. The container's profile is kept, so building it again restores " +
              'your session. Building takes several minutes.',
            label: 'Delete image',
          });
          if (!go) return;
          const { job } = await post('/api/docker', {
            selector: docker,
            action: 'purge',
          });
          watch(job, `Removing Docker image · ${row.name}`);
        },
        true,
      );
    }
  }

  // The row's button is Docker, so the native launcher has to be somewhere -
  // including on a version that is not downloaded yet, which is most of them.
  // Not offered while the container is up: that entry is already in the block
  // above.
  // Not when the vendor has stopped serving it: "anyway" is for a launch that
  // might work, and this one cannot be fetched at all. An already-downloaded copy
  // is a different matter - that one is on disk and still starts.
  if (row.dockerOnly && !row.dockerRunning && (row.installed || !row.nativeGone)) {
    const label = row.installed
      ? 'Launch natively anyway'
      : 'Download and launch natively';
    item('play', label, async () => {
      const { job } = await post('/api/launch', {
        selector,
        ...launchOptions(),
      });
      watch(job, row.name);
    });
  }

  if (row.installed) {
    menu.append(document.createElement('hr'));
    item(
      'reset',
      'Reset profile',
      async () => {
        const go = await askConfirm({
          title: `Reset the profile for ${row.name}?`,
          body: 'Cookies, logins and storage for this version are deleted. The browser itself stays, so the next launch starts clean.',
          label: 'Reset profile',
        });
        if (!go) return;
        const { job } = await post('/api/clean', { selector });
        watch(job, `Resetting profile · ${row.name}`);
      },
      true,
    );
    item(
      'trash',
      `Delete browser (${mb(row.sizeBytes)})`,
      async () => {
        const go = await askConfirm({
          title: `Delete the downloaded ${row.name}?`,
          body: `Frees ${mb(row.sizeBytes)}. The profile is kept, so downloading it again restores your session.`,
          label: 'Delete browser',
        });
        if (!go) return;
        const { job } = await post('/api/remove', { selector });
        watch(job, `Removing ${row.name}`);
      },
      true,
    );
    item(
      'trash',
      `Delete browser and profile (${mb(row.sizeBytes + row.profileBytes)})`,
      async () => {
        const go = await askConfirm({
          title: `Delete ${row.name} and its profile?`,
          body: `Frees ${mb(row.sizeBytes + row.profileBytes)}. Cookies and logins for this version are gone for good.`,
          label: 'Delete both',
        });
        if (!go) return;
        const { job } = await post('/api/remove', {
          selector,
          withProfile: true,
        });
        watch(job, `Removing ${row.name}`);
      },
      true,
    );
  }

  container.append(menu);
  openMenu = menu;

  // The shelf is a scroll container: near its bottom edge a downward menu would
  // be clipped rather than overflowing the page, so it flips above the row.
  const rect = container.getBoundingClientRect();
  if (rect.bottom + menu.offsetHeight + 12 > window.innerHeight)
    menu.classList.add('up');
}

/* ---------- status bar ---------- */

// One job at a time gets the status bar: whatever the log panel is watching if it
// is still running, otherwise the first piece of background work.
function activeJob() {
  const running = state ? state.jobs : [];
  return (
    running.find((job) => job.id === watching) ||
    running.find((job) => job.kind !== 'launch') ||
    running[0] ||
    null
  );
}

function renderStatusBar() {
  const job = activeJob();
  const bar = $('job-bar');

  // Everything else that is busy, reachable in one click.
  const others = (state ? state.jobs.length : 0) - (job ? 1 : 0);
  const more = $('job-more');
  more.hidden = others < 1;
  more.textContent = others < 1 ? '' : `+${others} more`;
  more.title = others < 1 ? '' : 'Show the other running jobs';

  if (!job) {
    // A container is not a job: the launcher exits the moment the desktop
    // answers, so with one running and nothing else happening this bar used to
    // read "Nothing running" underneath an open browser.
    const containers = state
      ? asArray(state.docker && state.docker.containers).length
      : 0;
    $('job-dot').dataset.state = containers ? 'running' : 'idle';
    $('job-title').textContent = !containers
      ? 'Ready'
      : containers === 1
        ? '1 version running in Docker'
        : `${containers} versions running in Docker`;
    $('job-detail').textContent = containers
      ? 'nothing else in progress'
      : 'Nothing running';
    bar.hidden = true;
    return;
  }

  const info = jobInfo.get(job.id) || null;
  const open = job.kind === 'launch' && info && info.phase === 'open';

  $('job-dot').dataset.state = open ? 'running' : 'working';
  $('job-title').textContent = jobTitle(job, info);

  if (open) {
    $('job-detail').textContent = 'running';
    bar.hidden = true;
    return;
  }

  const percent = info ? info.percent : null;
  // The byte counts and time left when curl is reporting them, the step's own
  // name when it has nothing to report.
  $('job-detail').textContent =
    (info && info.detail) || `${workWord(job, info)}…`;
  bar.hidden = false;
  bar.classList.toggle('indeterminate', percent == null);
  $('job-bar-fill').style.width = percent == null ? '' : `${percent}%`;
}

// /api/state lists the running jobs but not their output, and the output is
// where the phase and the meter are. One read per running job per refresh.
async function sampleJobs() {
  const running = state
    ? state.jobs.filter((job) => job.kind !== 'doctor')
    : [];
  await Promise.all(
    running.map(async (job) => {
      if (job.id === watching) return; // pollJob is already reading this one
      try {
        noteJob(job, (await api(`/api/job/${job.id}`)).output);
      } catch {
        /* the next refresh will try again */
      }
    }),
  );
  for (const id of [...jobInfo.keys()]) {
    if (id !== watching && !running.some((job) => job.id === id))
      jobInfo.delete(id);
  }
  for (const id of [...stopping]) {
    if (!state.jobs.some((job) => job.id === id)) stopping.delete(id);
  }
}

// Rows carry a live percentage, so the 700ms poll repaints them - but only when
// something actually moved, and never over an open menu.
let lastPaint = '';

const paintSignature = () =>
  !state
    ? ''
    : state.jobs
        .map((job) => {
          const info = jobInfo.get(job.id) || {};
          return `${job.id}:${info.phase}:${info.percent}`;
        })
        .join('|');

function repaintIfMoved() {
  if (!state || popoverOpen()) return;
  if (paintSignature() === lastPaint) return;
  render();
}

// Reading a job's output is also how the page learns a download finished: the
// CLI prints "ready." between the last meter frame and the browser starting, and
// a launch job keeps running long after that, so job completion cannot stand in
// for it.
function noteJob(job, output) {
  const before = jobInfo.get(job.id);
  const info = readJob(output);
  jobInfo.set(job.id, info);
  if (before && before.phase !== info.phase && info.phase === 'ready') {
    flash(`${jobName(job)} downloaded`);
  }
  return info;
}

/* ---------- job log ----------
   Several versions can be busy at once - two browsers open while a third
   downloads - so the panel is a switcher over the running jobs rather than one
   slot that whichever job started last takes over. */

function setLogOpen(open) {
  $('log-panel').hidden = !open;
  $('log-btn-label').textContent = open ? 'Hide log' : 'Show log';
}

/* ---------- the log panel's height ----------
   A download and a container build are both minutes of output and the panel was
   a fixed 150px of it. Dragging its top edge sets the height, because the panel
   is docked to the bottom and the top edge is the one that moves.

   Clamped both ways: too short and the panel is a slot with no text in it, too
   tall and the shelf it is covering has nowhere left to be. */
const LOG_H_KEY = 'engineshelf.logHeight';
const LOG_H_MIN = 90;
const logHeightMax = () => Math.max(LOG_H_MIN, Math.round(window.innerHeight * 0.62));

function setLogHeight(px, remember = true) {
  const height = Math.min(Math.max(Math.round(px), LOG_H_MIN), logHeightMax());
  $('log-panel').style.setProperty('--log-h', `${height}px`);
  if (!remember) return;
  try {
    localStorage.setItem(LOG_H_KEY, String(height));
  } catch {
    /* a private window forbids it; the height just does not outlive the tab */
  }
}

(function makeLogResizable() {
  const grip = $('log-grip');
  const panel = $('log-panel');
  const out = $('log-out');
  let stored = null;
  try {
    stored = Number(localStorage.getItem(LOG_H_KEY));
  } catch {
    stored = null;
  }
  if (stored) setLogHeight(stored, false);

  let startY = 0;
  let startH = 0;

  const move = (event) => {
    // Up is taller: the panel grows towards the pointer, not away from it.
    setLogHeight(startH + (startY - event.clientY));
  };
  const up = () => {
    panel.classList.remove('is-resizing');
    window.removeEventListener('pointermove', move);
    window.removeEventListener('pointerup', up);
  };

  grip.addEventListener('pointerdown', (event) => {
    event.preventDefault();
    startY = event.clientY;
    startH = out.getBoundingClientRect().height;
    panel.classList.add('is-resizing');
    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', up);
  });

  // Reachable without a pointer, which a separator with a tabindex has to be.
  grip.addEventListener('keydown', (event) => {
    const step = event.shiftKey ? 60 : 20;
    const now = out.getBoundingClientRect().height;
    if (event.key === 'ArrowUp') setLogHeight(now + step);
    else if (event.key === 'ArrowDown') setLogHeight(now - step);
    else return;
    event.preventDefault();
  });

  // A window that shrinks below what the stored height allows.
  window.addEventListener('resize', () => {
    const now = out.getBoundingClientRect().height;
    if (now > logHeightMax()) setLogHeight(logHeightMax(), false);
  });
})();

// Kept in one place because three callers add to it: watch(), the state poll for
// jobs this window did not start, and the log panel when a job it is showing ends.
function remember(job) {
  const had = jobSeen.get(job.id);
  jobSeen.set(job.id, {
    id: job.id,
    kind: job.kind,
    revision: job.revision,
    // A label from the state is better than the one watch() guessed, and a
    // guessed one is better than nothing.
    label: job.label || (had && had.label) || '',
    done: Boolean(job.done),
  });
  // Newest first, oldest dropped: the strip is one line and 40 downloads into a
  // session the first one is not what anybody is looking for.
  while (jobSeen.size > JOB_TABS) {
    const oldest = jobSeen.keys().next().value;
    if (oldest === watching) break;
    jobSeen.delete(oldest);
  }
}

function renderLogTabs() {
  const tabs = $('log-tabs');
  tabs.textContent = '';

  const live = state ? state.jobs : [];
  for (const job of live) remember(job);
  // Running first, then finished, each newest first - so the thing that is
  // actually happening is never behind something that already happened.
  const seen = [...jobSeen.values()].reverse();
  const running = new Set(live.map((job) => job.id));
  const list = [
    ...seen.filter((job) => running.has(job.id)),
    ...seen.filter((job) => !running.has(job.id)),
  ].map((job) => ({ ...job, kind: running.has(job.id) ? job.kind : 'done' }));

  // With one job there is nothing to switch between, so it reads as a title.
  $('log-title').hidden = list.length > 1;
  $('log-title').textContent = list.length > 1 ? '' : watchedTitle;
  tabs.hidden = list.length < 2;
  if (list.length < 2) return;

  for (const job of list) {
    const info = jobInfo.get(job.id) || null;
    const tab = document.createElement('button');
    tab.type = 'button';
    tab.className = `log-tab${job.id === watching ? ' is-on' : ''}`;

    const dot = document.createElement('span');
    dot.className = 'dot';
    dot.dataset.state =
      job.kind === 'done'
        ? 'idle'
        : info && info.phase === 'open'
          ? 'running'
          : info && info.phase === 'downloading'
            ? 'downloading'
            : 'working';

    const name = document.createElement('span');
    name.className = 'name';
    name.textContent = jobName(job);

    tab.append(dot, name);
    tab.title =
      job.kind === 'done' ? `${jobName(job)} — finished` : jobTitle(job, info);
    if (job.id !== watching) tab.onclick = () => watch(job.id, jobName(job));
    tabs.append(tab);
  }
}

function watch(jobId, title) {
  remember({ id: jobId, kind: 'job', revision: null, label: title });
  watching = jobId;
  watchedTitle = title;
  pollFailures = 0;
  setLogOpen(true);
  setLogCancel(null);
  $('log-status').textContent = 'running…';
  $('log-out').textContent = '';
  renderLogTabs();
  pollJob();
}

// The panel is where a long download is actually watched, so it is also where
// it has to be possible to call one off: the row's own button is as often as not
// scrolled out of sight behind it.
function setLogCancel(job, info) {
  const button = $('log-cancel');
  const offer =
    Boolean(job) && job.status === 'running' && CANCELLABLE.has(job.kind);
  button.hidden = !offer;
  if (!offer) return;
  // A launch job is a download first and a browser afterwards, and the same
  // request ends either - but "Cancel" over a browser that is already up reads
  // as though something were being thrown away.
  const up = Boolean(info) && info.phase === 'open';
  const going = stopping.has(job.id);
  // The same two glyphs the rows use, and for the same reason: a cross calls
  // off work that has not finished, the square shuts down something that is
  // already up. One button doing both had to say which it was.
  $('log-cancel-icon').innerHTML = icon(up ? 'stop' : 'x');
  $('log-cancel-label').textContent = going
    ? up
      ? 'Stopping…'
      : 'Cancelling…'
    : up
      ? 'Stop'
      : 'Cancel';
  button.disabled = going;
  button.onclick = () =>
    cancelJob(job.id, `${up ? 'Stopping' : 'Cancelling'} ${jobName(job)}`);
}

async function pollJob() {
  if (!watching) return;
  const jobId = watching;
  let job;
  try {
    job = await api(`/api/job/${jobId}`);
  } catch (error) {
    if (watching !== jobId) return;
    // Giving up quietly is what made a server-side error look like a job that
    // ran forever: "running…", no log, no clue. One hiccup is worth retrying;
    // four in a row is worth saying out loud.
    if (++pollFailures < 4) {
      setTimeout(pollJob, 700);
      return;
    }
    $('log-status').textContent = 'cannot read this job';
    $('log-out').textContent =
      `${error.message}\n\nThe job itself may well be running - this is the manager ` +
      'failing to read its output. The version list still updates, and the launcher ' +
      'writes its own log under the EngineShelf home directory.';
    return;
  }
  if (watching !== jobId) return;
  pollFailures = 0;

  const log = $('log-out');
  const atBottom = log.scrollTop + log.clientHeight >= log.scrollHeight - 20;
  // curl draws its progress bar with carriage returns; keep only the last frame.
  log.textContent = (job.output || '')
    .split('\n')
    .map((line) => line.split('\r').pop())
    .join('\n');
  if (atBottom) log.scrollTop = log.scrollHeight;

  const info = noteJob(job, job.output);

  const status = $('log-status');
  setLogCancel(job, info);
  if (job.status === 'running') {
    status.textContent =
      info.phase === 'open'
        ? 'running'
        : info.detail
          ? `${workWord(job, info)} · ${info.detail}`
          : `${workWord(job, info)}…`;
    renderStatusBar();
    repaintIfMoved();
    setTimeout(pollJob, 700);
  } else {
    status.textContent =
      job.status === 'done'
        ? 'finished'
        : job.status === 'stopped'
          ? 'stopped'
          : `failed (exit ${job.code})`;
    jobInfo.delete(jobId);
    if (job.status === 'done')
      flash(`${$('log-title').textContent} — finished`);
    refresh();
  }
}

// A request that failed before a job existed still has to be visible somewhere,
// and the log panel is where the user is already looking for output.
function showJobFailure(title, message) {
  watching = null;
  watchedTitle = title;
  setLogOpen(true);
  setLogCancel(null);
  renderLogTabs();
  $('log-title').textContent = title;
  $('log-status').textContent = 'failed';
  $('log-out').textContent = message;
}

$('log-close').onclick = () => {
  watching = null;
  watchedTitle = '';
  setLogOpen(false);
};

$('log-btn').onclick = () => {
  const open = $('log-panel').hidden;
  setLogOpen(open);
  if (!open) return;
  const job = activeJob();
  if (!watching && job) {
    watch(job.id, jobName(job));
  } else if (!watching) {
    watchedTitle = 'No job yet';
    renderLogTabs();
    $('log-status').textContent =
      'output from installs, launches and clean-ups shows up here';
  }
};

/* ---------- toast ---------- */

let toastTimer = null;

function flash(message, tone = 'ok') {
  $('toast-text').textContent = message;
  $('toast-icon').innerHTML = icon(tone === 'ok' ? 'ok' : 'warn');
  const toast = $('toast');
  toast.classList.toggle('warn', tone !== 'ok');
  toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    toast.hidden = true;
  }, 2600);
}

/* ---------- confirm ----------
   Deleting a browser and resetting a profile are the two things here that cannot
   be undone, and window.confirm put a browser-chrome dialog in front of them
   that says which host is asking rather than what is about to happen. */

function askConfirm({ title, body, label }) {
  const dialog = $('confirm-dialog');
  $('confirm-title').textContent = title;
  $('confirm-body').textContent = body;
  $('confirm-ok').textContent = label;
  dialog.returnValue = '';
  return new Promise((resolve) => {
    dialog.addEventListener('close', function once() {
      dialog.removeEventListener('close', once);
      resolve(dialog.returnValue === 'ok'); // Escape closes with neither value
    });
    dialog.showModal();
  });
}


/* ---------- controls ---------- */

$('job-more').onclick = () => {
  setLogOpen(true);
  if (!watching) {
    const job = activeJob();
    if (job) watch(job.id, jobName(job));
  }
  renderLogTabs();
};

$('theme-btn').onclick = () => {
  const root = document.documentElement;
  const dark = root.dataset.theme
    ? root.dataset.theme === 'dark'
    : matchMedia('(prefers-color-scheme: dark)').matches;
  root.dataset.theme = dark ? 'light' : 'dark';
  writeStored(THEME_KEY, root.dataset.theme);
};

$('url').addEventListener('input', () => {
  $('url-clear').hidden = !$('url').value;
});
$('url-clear').onclick = () => {
  $('url').value = '';
  $('url-clear').hidden = true;
  $('url').focus();
};

$('query').addEventListener('input', (event) => {
  view.query = event.target.value;
  $('query-clear').hidden = !view.query;
  if (state) render();
});
$('query-clear').onclick = () => {
  view.query = '';
  $('query').value = '';
  $('query-clear').hidden = true;
  if (state) render();
};

for (const button of document.querySelectorAll('[data-filter]')) {
  button.onclick = () => {
    view.filter = button.dataset.filter;
    if (state) render();
  };
}

/* ---------- guarding an accidental close ----------
   Closing the window ends the session: the server stops, the browsers it
   launched close, and the containers it started come down. That is the point,
   but not something a stray click on the X should be able to do while a download
   is halfway through.

   The prompt is the browser's own. Nothing else can stop a window from closing,
   and its wording belongs to the browser - so it is registered for exactly what
   it is good for, and only while there is something to lose. Idle, the window
   closes as cleanly as any other. One limit worth knowing: a browser only shows
   that prompt if the page has been interacted with, so a window opened and never
   clicked in closes without asking. */

function runningNow() {
  const rows = state ? [...state.versions, ...state.extra].map(decorate) : [];
  return {
    browsers: rows.filter((row) => row.running).length,
    containers: rows.filter((row) => row.dockerRunning).length,
    jobs: state ? state.jobs.filter((job) => job.kind !== 'launch').length : 0,
  };
}

// The macOS app hosts this page in a window of its own, where beforeunload does
// not exist - so the same question it answers has to be answerable from outside
// the page, and this is the one thing the window asks before it closes.
window.engineShelfRunning = runningNow;

let guarded = false;

function guardClose(event) {
  event.preventDefault();
  event.returnValue = ''; // the older spelling, still what some engines read
  return '';
}

function setCloseGuard() {
  const { browsers, containers, jobs: busy } = runningNow();
  const worth = browsers + containers + busy > 0;
  if (worth === guarded) return;
  guarded = worth;
  if (worth) window.addEventListener('beforeunload', guardClose);
  else window.removeEventListener('beforeunload', guardClose);
}

/* ---------- refresh loop ----------
   Four seconds is right for a shelf where nothing is happening, and far too
   slow for one where a download is: the row's percentage, the status bar and the
   disk read-out all come from here. So the clock follows the work - a second
   while anything is running, four when it is not. */

let refreshTimer = null;
let jobRevision = null; // what the heartbeat last said the server was running

function keepLooking() {
  clearTimeout(refreshTimer);
  const busy = Boolean(state && state.jobs && state.jobs.length);
  refreshTimer = setTimeout(() => {
    // Not over an open menu or dialog: a repaint would close what someone is
    // reading. The heartbeat keeps the server happy in the meantime, and
    // refresh() sets the next tick itself.
    if (popoverOpen() || document.querySelector('dialog[open]')) keepLooking();
    else refresh();
  }, busy ? 1000 : 4000);
}


async function refresh() {
  let next;
  try {
    next = await api('/api/state');
  } catch (error) {
    keepLooking();
    showState({
      glyph: 'warn',
      tone: 'error',
      title: 'Cannot reach the manager',
      detail:
        `${error.message}. The local server is not answering — it was probably ` +
        'stopped. Reopen EngineShelf, or run ./gui.sh from the project folder.',
      actionLabel: 'Try again',
      onAction: refresh,
    });
    return;
  }

  next.jobs = asArray(next.jobs);
  next.versions = asArray(next.versions);
  next.extra = asArray(next.extra);
  next.hostPlatforms = asArray(next.hostPlatforms);
  if (next.doctor) next.doctor.components = asArray(next.doctor.components);
  // A build only lands in `extra` because it is sitting in the builds directory,
  // so it is installed by definition - the server does not spell that out.
  for (const row of next.extra) {
    row.installed = true;
    row.extra = true;
  }
  state = next;
  await sampleJobs();
  // The clock is set from what this just found: a shelf with a download on it
  // is worth a second, an idle one is not.
  keepLooking();

  try {
    render();
    bootingDone();
  } catch (error) {
    // Drawing the page failing is not the server being down. Saying it was sent
    // the last one of these looking for a stopped server that was running fine.
    showState({
      glyph: 'warn',
      tone: 'error',
      title: 'Could not draw the version list',
      detail:
        `${error.message}. The manager itself is still running, so this is a bug ` +
        'in the page rather than a problem with your machine.',
      actionLabel: 'Reload',
      onAction: () => location.reload(),
    });
  }
}

(async function boot() {
  paintIcons();
  drawSkeleton();
  buildDropdown(
    'gpu-drop',
    'gpu-btn',
    'gpu-menu',
    'gpu-label',
    [
      { value: 'auto', label: 'GPU auto' },
      { value: 'on', label: 'Force GPU on' },
      { value: 'off', label: 'Force GPU off' },
    ],
    () => view.gpu,
    (value) => {
      view.gpu = value;
    },
  );

  buildDropdown(
    'sort-drop',
    'sort-btn',
    'sort-menu',
    'sort-label',
    [
      { value: 'new', label: 'Newest first' },
      { value: 'old', label: 'Oldest first' },
      { value: 'disk', label: 'Disk used' },
    ],
    () => view.sort,
    (value) => {
      view.sort = value;
      if (state) render();
    },
  );

  TOKEN = (await (await fetch('/api/token')).json()).token;

  // Before the first paint, so no row is drawn twice - once blank and once with
  // its features. Not fatal if it fails: an older server has no such endpoint,
  // and the shelf then reads as it did before there were any features to read.
  try {
    featureIndex = await api('/api/features');
  } catch {
    featureIndex = {};
  }

  await refresh();

  // The heartbeat that tells the server this window still exists. Deliberately
  // not folded into the refresh above: that one pauses while a menu or a dialog
  // is open, which is long enough for the server to decide nobody is home.
  //
  // It carries one more thing: which jobs the server has. Two windows onto one
  // manager each keep their own clock, so a download started in one used to
  // take a whole cycle to appear in the other; this notices in one beat and
  // looks straight away.
  setInterval(async () => {
    let beat;
    try {
      beat = await api('/api/ping');
    } catch {
      return; // the next one will do
    }
    if (beat.revision === undefined || beat.revision === jobRevision) return;
    const first = jobRevision === null;
    jobRevision = beat.revision;
    if (!first && !popoverOpen() && !document.querySelector('dialog[open]')) {
      refresh();
    }
  }, 1500);
})();
