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
  // A three-quarter arc, drawn to be spun by CSS. The log tabs needed one glyph
  // that says "this is working" without claiming to know what the work is: a
  // dozen tabs each carrying a differently coloured dot said nothing at all.
  spinner: '<path d="M12 3.2a8.8 8.8 0 1 0 8.8 8.8"/>',
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
// Whether the manager on the other end keeps logs at all. The page is served off
// disk and the manager is a process that was started once, so updating the
// project and reloading leaves a new page talking to an old server - and an old
// one has no streams to list. Saying so beats an empty panel reading "No job
// yet" over a download that is running.
let managerLogs = true;
const jobInfo = new Map(); // job id -> {phase, percent, detail} read out of its output
// The log panel's own state - which stream it shows and what it holds of each -
// lives with the rest of that section, further down.
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
  // A dependency install is a job like any other and its log has a head like any
  // other; without a word of its own the panel read "working..." over it.
  doctor: 'installing',
};

// Which jobs the manager offers to interrupt. A download or an image build is
// minutes of work with nothing lost by calling it off; a delete or a profile
// reset is over in a moment and cutting one short leaves half a directory.
/* ---------- what can be called off ----------
   Fetching and building are minutes of work, and the only way out of either used
   to be quitting the manager. A delete or a profile reset is over in a moment,
   and half a deleted directory is worse than waiting for it - which is why
   `remove` and `clean` are not in here.

   The Docker side has to draw the same line: `docker` is one kind covering every
   verb, so "Delete Docker image" wore a cancel while "Delete browser" did not,
   and they are the same act on the two routes. Stopping is excluded for a second
   reason - interrupting `docker stop` leaves the browser inside holding the lock
   in its profile volume, which is what made a version permanently unstartable. */
const CANCELLABLE = new Set(['install', 'launch', 'docker']);
const DOCKER_FINAL = new Set(['stop', 'clean', 'purge']);

const cancellable = (job) =>
  CANCELLABLE.has(job.kind) &&
  !(job.kind === 'docker' && DOCKER_FINAL.has(job.action));

// A docker job says which verb it is rather than falling back to the word
// "docker": "docker..." over a container coming down read as a noun with an
// ellipsis after it, where the row beside it said "stopping...".
const DOCKER_WORD = {
  start: 'starting',
  stop: 'stopping',
  build: 'building',
  rebuild: 'rebuilding',
  clean: 'resetting',
  purge: 'removing',
};

const workWord = (job, info) =>
  (info && WORK_WORD[info.phase]) ||
  (job.kind === 'docker' && DOCKER_WORD[job.action]) ||
  WORK_WORD[job.kind] ||
  'working';
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
  if (!row) {
    // The log's label is this page's own name for the row - "Chromium 125" -
    // where job.label is the server's sentence about the work, "Installing
    // Chromium 125". Falling straight through to that is what put "Installing
    // Installing Chromium 125" in the status bar: a milestone installs, its row
    // starts answering to the revision instead, and the lookup above stops
    // finding the selector the job was started with.
    const stream = job.stream ? logStreams.get(job.stream) : null;
    return (stream && !stream.local && stream.label) || job.label;
  }
  const label = row.label || row.version;
  return label ? `${engineName(row.engine)} ${label}` : `r${row.revision}`;
}

function jobTitle(job, info) {
  if (job.kind === 'doctor') return job.label;
  const name = jobName(job);
  if (info && info.phase === 'open') return name;
  if (info && info.phase === 'ready') return `Starting ${name}`;
  // With the verb, where there is one to say: a stop, a build and an image purge
  // all read "Docker · Firefox 55" otherwise, and two of them can be on the
  // status bar at the same time.
  if (job.kind === 'docker')
    return job.action && job.action !== 'start'
      ? `Docker ${job.action} · ${name}`
      : `Docker · ${name}`;
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

// "349 MB · 12 MB profile", and just "349 MB" when the profile does not round to
// anything. "0 MB profile" is a phrase about the absence of a thing, and it turns
// up on every freshly downloaded build - mb() rounds, so a profile directory of a
// few hundred KB reads as zero too. One helper for both routes' lines, because
// the Docker one had already stopped saying it and the native one had not.
function sizeWithProfile(bytes, profile) {
  const held = mb(profile);
  return mb(bytes) + (held === '0 MB' ? '' : ` · ${held} profile`);
}

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

/* The virtual screen a container is started with. The framebuffer cannot be
   resized once the container is up - Xvfb fixes it at start and x11vnc can only
   report a resize the X server made, never ask for one - so this is decided
   here, on the way in.
   The box in the header is the same one the native launcher takes its window
   size from; empty means the display this desktop is about to be looked at on,
   which is the thing the image's fixed 1440x900 could never know. Clamped,
   because every pixel of that framebuffer is drawn by an emulated x86 and a 4K
   desktop under emulation is not a kindness. */
function desktopScreen() {
  const typed = $('size').value.trim();
  if (/^\d{3,4}x\d{3,4}$/.test(typed)) return typed;
  const clamp = (value, low, high, fallback) =>
    Math.min(high, Math.max(low, Math.round(value || fallback)));
  const w = clamp(screen.availWidth, 800, 2560, 1440);
  const h = clamp(screen.availHeight, 600, 1600, 900);
  return `${w}x${h}`;
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
  // The two routes' work, kept apart. They can both be going at once - a native
  // download beside a container build - and a row that folded them into one
  // could only ever show and cancel whichever the cascade reached first.
  const live = state ? state.jobs : [];
  // By the log it writes to first, because that is the one identity that does
  // not move: a Chromium row's selector is its milestone until the build lands
  // and its revision afterwards, so a job started as "105" stopped matching the
  // row the moment it succeeded. The selectors are still checked, for a job an
  // older page or a hand-made request started without naming a stream.
  const streamKey = streamKeyFor(engine, row.id ?? selector);
  const onThisRow = (entry) =>
    entry.stream === streamKey ||
    String(entry.revision) === selector ||
    (dockerSelector && String(entry.revision) === dockerSelector);
  const nativeBusy =
    live.find(
      (entry) =>
        onThisRow(entry) &&
        entry.kind !== 'launch' &&
        entry.kind !== 'doctor' &&
        entry.kind !== 'docker',
    ) || null;
  const dockerBusy =
    live.find((entry) => onThisRow(entry) && entry.kind === 'docker') || null;
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
    // What each route is doing, for the buttons. `busy` above is still whichever
    // of them the row's dot and progress bar read.
    nativeJob: launchJob || nativeBusy,
    dockerJob: dockerBusy,
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
      button.onclick = () => watch(busy.stream, component.label);
      row.classList.add('busy');
    } else {
      button.classList.add('accent');
      button.textContent = starting ? 'Start it' : 'Install';
      button.onclick = async () => {
        button.disabled = true;
        try {
          const { stream } = await post('/api/doctor-install', {
            component: component.id,
            streamLabel: component.label,
          });
          watch(stream, component.label, { auto: true });
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
  dropSplash();
}

/* ---------- splash ----------
   index.html draws it; this fills in the two things markup cannot.

   A splash that flashes is worse than none: a warm start answers in under a
   tenth of a second, and a curtain that opens and shuts in that time reads as a
   glitch. So it stays for as long as the marks take to draw and no longer - a
   cold start is covered, a warm one is a flourish. */

const SPLASH_MIN_MS = 1010; // the fourth mark's delay plus its own draw
const SPLASH_FADE_MS = 320; // and the CSS transition that takes it away
/* And the point at which a boot that has not finished is a boot that is not
   going to. Generous: a cold start that has to ask Docker is seconds, not
   milliseconds. */
const SPLASH_LIMIT_MS = 20000;
const splashOpened = performance.now();

function armSplash() {
  const splash = $('splash');
  if (!splash) return;
  /* A stroke can only be drawn on if its length is known, and these shapes are
     nothing alike: Chromium's outer circle measures 57 units, Firefox's flame
     over 90. pathLength calls every one of them 100, so four marks of very
     different sizes draw in the same time and land together. */
  for (const shape of splash.querySelectorAll('svg.i > *'))
    shape.setAttribute('pathLength', '100');

  /* A boot that never finishes must not leave a sheet over the whole window.
     What is underneath is the skeleton - what the first second looked like
     before there was a splash - and whatever went wrong can then draw its own
     answer over that. The same reasoning as failIfSilent in
     tools/launcher/launcher.m: a window saying something is worth more than a
     window that is still pretending. */
  setTimeout(dropSplash, SPLASH_LIMIT_MS);
}

// What the boot is on, in the same words the shelf itself would use.
function splashSays(words) {
  const say = $('splash-say');
  if (say) say.textContent = words;
}

function dropSplash() {
  const splash = $('splash');
  if (!splash || splash.classList.contains('is-gone')) return;
  const left = Math.max(0, SPLASH_MIN_MS - (performance.now() - splashOpened));
  setTimeout(() => {
    splash.classList.add('is-gone');
    // Gone from the page, not merely invisible: nothing ever brings it back,
    // and a fixed sheet over the shelf is not a thing to leave lying about.
    setTimeout(() => splash.remove(), SPLASH_FADE_MS);
  }, left);
}

/* ---------- rendering ---------- */

function render() {
  const rows = [...state.versions, ...state.extra].map(decorate);
  // Before renderLogTabs below: the tab marks read this to tell a container that
  // is up from a container job that has ended.
  noteLiveRows(rows);
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
  // After the strip, which is what sets tabsShown.
  if (!$('log-panel').hidden) renderLogHead();

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
  // And the work in progress reads on the line of the copy it is building. An
  // image build put "docker…" on the top line, against the screen glyph in the
  // native colour - a row fetching a container looked like a row fetching a
  // build.
  // Each line says what its own route is doing, or what it holds on disk. Read
  // off `busy` - the one job the row folded both routes into - the docker line
  // went on reporting a gigabyte of image while that image was being rebuilt,
  // and a native download put "downloading…" on whichever line came first.
  const busyWord = (job) =>
    job ? `${workWord(job, jobInfo.get(job.id) || null)}…` : '';
  sizeLine(
    node.querySelector('[data-size]'),
    'desktop',
    row.nativeJob && !row.running
      ? busyWord(row.nativeJob)
      : row.installed
        ? sizeWithProfile(row.sizeBytes, row.profileBytes)
        : '',
  );
  sizeLine(
    node.querySelector('[data-size-docker]'),
    'cube',
    row.dockerJob
      ? busyWord(row.dockerJob)
      : row.dockerImage
        ? sizeWithProfile(row.dockerImage, row.dockerProfileBytes)
        : '',
  );

  // One meter per route with work in flight, in the same order as the buttons.
  // A browser that is already up is left out: its launch job runs for as long as
  // the window does and there is nothing to measure, which is why an open
  // browser never had a bar and still does not.
  const meters = [row.nativeJob, row.dockerJob].filter((job) => {
    if (!job) return false;
    const info = jobInfo.get(job.id) || null;
    return !(info && info.phase === 'open');
  });
  if (meters.length) {
    const holder = node.querySelector('[data-progress]');
    holder.hidden = false;
    for (const job of meters) {
      const info = jobInfo.get(job.id) || null;
      const percent = info ? info.percent : null;
      const bar = document.createElement('span');
      bar.className = 'row-bar';
      // Determinate while curl is reporting, a moving stripe for the steps that
      // cannot be measured - unpacking, deleting, waiting on Docker.
      if (percent == null) bar.classList.add('indeterminate');
      const fill = document.createElement('i');
      if (percent != null) fill.style.width = `${percent}%`;
      bar.append(fill);
      holder.append(bar);
    }
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

/* ---------- what a row offers ----------
   Native and Docker are two ways of running one version, and they can both be
   busy at the same time: a build downloading while its container image builds, a
   browser open while the container behind it is still up. This used to be one
   cascade of else-ifs over a single job, so whichever branch matched first was
   the whole row - a running container behind a running browser had no Stop here
   at all, only an entry in the menu, on a row with the space to show it.

   Each route now reports its own controls. One route busy reads exactly as it
   did; both busy gets a line each, the same shape the size column beside it has
   always used. */

function renderActions(container, row) {
  const lines = document.createElement('div');
  lines.className = 'row-lines';

  const native = nativeControls(row);
  const docker = dockerControls(row);

  if (native.length && docker.length) {
    container.classList.add('two-routes');
    lines.append(controlLine(native), controlLine(docker));
  } else {
    lines.append(
      controlLine(native.length || docker.length ? [...native, ...docker] : idleControls(row)),
    );
  }
  container.append(lines);

  // Only when it leads somewhere. With both routes busy every entry can be gated
  // off, and a button that opens an empty menu is worse than no button.
  if (menuPlan(row).length) {
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
}

const controlLine = (buttons) => {
  const line = document.createElement('div');
  line.className = 'row-line';
  for (const button of buttons) line.append(button);
  return line;
};

function button(kind, glyph, label, title, handler) {
  const node = document.createElement('button');
  node.className = `btn${kind ? ` ${kind}` : ''}`;
  node.append(iconSpan(glyph), label);
  node.title = title;
  if (handler) node.onclick = () => handler(node);
  else node.disabled = true;
  return node;
}

/* ---------- the native route ---------- */

function nativeControls(row) {
  // Work in flight speaks first, and a browser told to close is work in flight:
  // its launch job runs until the window is actually gone. SIGTERM to the process
  // group takes a moment, and a button still reading "Stop" invited a second
  // press.
  if (row.nativeJob && stopping.has(row.nativeJob.id))
    return busyControls(row, row.nativeJob);

  if (row.running) {
    // Two buttons while it is up. The window is open behind this one and the row
    // had no way back to it: every route to a running version was either Stop or
    // a fresh launch, and a fresh launch of a browser that is already running is
    // not one.
    return [
      button('accent', 'desktop', 'Open', 'Bring this browser window to the front',
        (node) => raiseNative(node, row)),
      button('warn', 'stop', 'Stop', 'Close this browser and everything it started',
        () => cancelJob(row.job.id, `Stopping ${row.name}`)),
    ];
  }
  return row.nativeJob ? busyControls(row, row.nativeJob) : [];
}

/* ---------- the Docker route ---------- */

function dockerControls(row) {
  // Work in flight speaks first here too, which is the whole point: `docker stop`
  // gives the browser inside ten seconds to close, so the container is still up
  // for all of them. Reading dockerRunning first put Open and Stop back on the
  // row for that entire window, where native was already saying "Stopping..." -
  // and a second press sent a second stop. A rebuild and an image delete take the
  // container down themselves, so neither leaves one there to offer either.
  if (row.dockerJob) return busyControls(row, row.dockerJob);

  if (row.dockerRunning) {
    const out = [];
    // The container is up, so the version is running even though no native
    // window is - and something is burning CPU that the row has to be able to
    // turn off. The way back to the desktop is the button beside it: it used to
    // be the first entry in the menu, one click behind the thing a running
    // container is for.
    if (row.dockerUrl) {
      out.push(
        button('accent', 'link', 'Open',
          'Open the desktop this container is running. The tab it opened is ' +
            'reused, so this focuses that one rather than making another.',
          () => openDesktop(row)),
      );
    }
    out.push(
      button('warn', 'stop', 'Stop', 'Stop the Docker container running this version',
        async (node) => {
          node.disabled = true;
          try {
            const { stream } = await post('/api/docker', {
              selector: row.dockerSelector,
              action: 'stop',
              ...streamBody(row),
            });
            watch(stream, row.name, { auto: true });
          } catch (error) {
            showJobFailure(`Stopping Docker · ${row.name}`, error.message);
            node.disabled = false;
            return;
          }
          refresh();
        }),
    );
    return out;
  }
  return [];
}

/* ---------- a job in flight, either route ---------- */

function busyControls(row, job) {
  const info = jobInfo.get(job.id) || null;
  const going = stopping.has(job.id);
  const up = Boolean(info) && info.phase === 'open';
  const downloading = Boolean(info) && info.phase === 'downloading';
  const percent = info ? info.percent : null;

  // Already on its way out. The word says which of the two it is waiting on -
  // one request ends a download and a browser that is already up - and there is
  // no second button beside it, which is what invited a second press: SIGTERM
  // reaches curl a moment before the job ends.
  //
  // A download in progress used to leave this saying "Install & launch", which
  // invited a second one while the first was still running.
  const label = going
    ? up
      ? 'Stopping…'
      : 'Cancelling…'
    : downloading && percent != null
      ? `${percent}%`
      : `${capitalise(workWord(job, info))}…`;
  const glyph = going
    ? 'clock'
    : downloading
      ? 'down-circle'
      : job.kind === 'docker'
        ? 'cube'
        : 'clock';

  // Every label in flight is a way into the log, stopping ones included: that is
  // where the answer to "what is it waiting for" is, and half of them used to be
  // a dead disabled button instead.
  const out = [
    button('', glyph, label, 'Show what this is doing', () =>
      watch(job.stream, row.name),
    ),
  ];
  if (going || !cancellable(job)) return out;

  const cancel = document.createElement('button');
  cancel.className = 'btn icon-btn warn';
  cancel.append(iconSpan('x'));
  // Only the fetching verbs reach here, so the words can be about the actual
  // one: "Cancel this Docker build" over a container coming up was wrong on both
  // counts.
  cancel.title =
    job.kind === 'docker'
      ? job.action === 'start'
        ? 'Cancel this container starting up'
        : 'Cancel this Docker build'
      : downloading
        ? 'Cancel this download'
        : 'Cancel this install';
  cancel.onclick = (event) => {
    event.stopPropagation();
    cancelJob(job.id, `Cancelling ${row.name}`);
  };
  out.push(cancel);
  return out;
}

/* ---------- nothing running: the one button that starts something ---------- */

// Whether Docker takes the row's own button, or stays in the menu behind it. A
// recommendation is not the whole story: what the button owes is the shortest
// way to a browser. An image already built is one click, so it keeps the button
// on a Docker-first row. An image that has yet to be built is minutes of work,
// and a native copy already on disk beats it every time - that row used to read
// "Get" over a version that was installed, with the one thing that could start
// right now hidden in the menu.
function dockerIsPrimary(row) {
  return Boolean(row.dockerOnly && (row.dockerImage || !row.installed));
}

function idleControls(row) {
  const selector = row.selector;
  const action = document.createElement('button');
  action.className = 'btn';

  if (dockerIsPrimary(row)) {
    // Here the container is not a fallback, it is the only way this version runs
    // on this machine - so it is the button, not something to be found in the
    // menu behind it. Ahead of "installed" deliberately: a build that is on disk
    // but cannot execute here is still not something to launch.
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
    // On a row that recommends the container this is still the button, because
    // the image is not built and this build is: one click against several
    // minutes. The recommendation is not lost - it is in the tooltip, in the
    // route marks, and one click away in the menu.
    action.title = row.dockerOnly
      ? 'Open this build. The container is the route that works here, but its ' +
        'image has still to be built - the menu beside this starts that.'
      : 'Open this build';
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
  return [action];
}

async function start(button, row) {
  button.disabled = true;
  try {
    const { stream } = await post('/api/launch', {
      selector: row.selector,
      ...launchOptions(),
      ...streamBody(row),
    });
    watch(stream, row.name, { auto: true });
  } catch (error) {
    showJobFailure(row.name, error.message);
    button.disabled = false;
    return;
  }
  refresh();
}

// One tab per container, and the same one every press. window.open with a name
// rather than '_blank' is what makes the second press land on the tab the first
// one opened, and the handle is kept as well because renavigating a named target
// reloads it - a reload of noVNC drops the session and redraws the whole desktop
// from scratch. Deliberately no 'noopener': it forces a fresh browsing context,
// which ignores the name, which is what cloned a tab on every press.
const desktopTabs = new Map();

function openDesktop(row) {
  const key = row.dockerSelector || row.selector || row.name;
  const name = `engineshelf-${String(key).replace(/[^a-zA-Z0-9]+/g, '-')}`;
  const seen = desktopTabs.get(key);
  // Still open and still pointed at this container: focus it and leave its URL
  // alone.
  if (seen && !seen.tab.closed && seen.url === row.dockerUrl) {
    seen.tab.focus();
    return;
  }
  // A container that was stopped and started again is on a new port, so the tab
  // that is open is showing a dead desktop - naming the target sends that same
  // tab to the new port rather than leaving it behind.
  const tab = window.open(row.dockerUrl, name);
  if (!tab) {
    flash('The browser blocked that tab - allow pop-ups for this page.', 'warn');
    return;
  }
  desktopTabs.set(key, { tab, url: row.dockerUrl });
  tab.focus();
}

// The native side of the same button. A container's desktop is a tab this page
// opened and can focus itself; a native window belongs to the machine, and the
// manager has no handle on it - so the server raises it. What that takes differs
// per platform and can be unavailable, which is why a failure is said out loud
// rather than leaving a button that looks like it did nothing.
async function raiseNative(button, row) {
  button.disabled = true;
  try {
    await post('/api/raise', { job: row.job.id });
  } catch (error) {
    flash(error.message, 'warn');
  }
  button.disabled = false;
}

// The launch options above are for the native launcher - a container brings up a
// whole desktop and takes none of them - so this is deliberately its own path
// rather than a flag on start().
async function startDocker(button, row) {
  return startDockerBy(button, row.dockerSelector, row.name, streamBody(row));
}

// Keyed by selector rather than by the row object, because the caller that
// starts a container does not always have one - the row menu passes a selector it
// read off the row minutes earlier.
async function startDockerBy(button, selector, name, stream = {}) {
  button.disabled = true;
  try {
    const { stream: key } = await post('/api/docker', {
      selector,
      action: 'start',
      screen: desktopScreen(),
      ...stream,
    });
    watch(key, name, { auto: true });
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

/* ---------- what the row's menu would offer ----------
   Keys, not buttons: the ... button has to know whether pressing it leads
   anywhere before it is drawn, and building the menu 288 times a repaint to find
   out is not an option. One list of conditions, read by both, so the button and
   the menu behind it cannot disagree - a ... that opened onto nothing was
   exactly that disagreement.

   An entry that starts work on a route is not offered while that route already
   has work in flight. A download in progress used to sit behind a menu still
   saying "Download only" and "Reset profile", and pressing either started a
   second job against the same directory: the row's own button had stopped
   offering it, and the menu behind the button had not. Per route, because the
   two are independent - a container building says nothing about whether the
   native build can be fetched. */
function menuPlan(row) {
  const plan = [];
  const nativeFree = !row.nativeJob;
  const dockerFree = !row.dockerJob;

  if (logStreams.has(streamKeyOf(row))) plan.push('log');

  // The row's button is Docker, so the native launcher has to be somewhere -
  // including on a version that is not downloaded yet, which is most of them.
  // Not while the container is up: "Launch natively as well" below is that
  // entry. Not when the vendor has stopped serving it either: "anyway" is for a
  // launch that might work, and this one cannot be fetched at all. An
  // already-downloaded copy is a different matter - that one is on disk and
  // still starts.
  if (
    nativeFree &&
    dockerIsPrimary(row) &&
    !row.dockerRunning &&
    (row.installed || !row.nativeGone)
  ) {
    plan.push('launch-anyway');
  }

  // Both ways of running this version are available and only one of them has the
  // row's button, so the other cannot be a dead end.
  if (nativeFree && row.dockerAvailable && row.dockerRunning && row.installed)
    plan.push('launch-as-well');

  // Nothing to download when the catalog has no build of this version for this
  // machine, or when the vendor has stopped serving the one it has.
  if (nativeFree && !row.installed && row.supported && !row.nativeGone)
    plan.push('download-only');

  if (row.dockerAvailable) {
    if (row.dockerRunning) {
      // Only when the native window has taken the row's Open button: both routes
      // are up, and the container's desktop cannot be the same button.
      if (row.dockerUrl && row.running) plan.push('open-desktop');
      // Not while a stop is already on its way, which is the one docker job that
      // can be running with the container still up.
      if (dockerFree) plan.push('stop-container');
    } else {
      // Not when the row's own button already is this: on a Docker-first row the
      // two read word for word the same.
      if (dockerFree && !dockerIsPrimary(row)) plan.push('docker-launch');
      // The other half of "Download only": fill the shelf now, use it later.
      if (dockerFree && !row.dockerImage) plan.push('docker-build');
      // The CLI has had `rebuild` since the container edition shipped and the
      // GUI never offered it, so the one thing you have to do after an image
      // fix - rebuild the images you already have - could only be done from a
      // terminal. Native's nearest equivalent is delete and fetch again, which
      // is two entries below.
      if (dockerFree && row.dockerImage) plan.push('docker-rebuild');
    }
  }

  // Everything below is destructive. A delete or a profile reset against a
  // directory that is being written to is the one case where "it is over in a
  // moment" stops being true.
  if (nativeFree && row.installed) plan.push('reset', 'delete-build', 'delete-both');
  // The Docker side of the same three. Its profile lives in a volume rather than
  // a directory, and until now nothing in the GUI could reset it or delete it
  // without also deleting the native build - "Delete everything" was the only
  // route to the volume, and there was no route at all to resetting it.
  if (dockerFree && row.dockerAvailable && row.dockerImage)
    plan.push('docker-reset', 'delete-image', 'delete-image-both');
  if (
    nativeFree &&
    dockerFree &&
    row.installed &&
    row.dockerAvailable &&
    row.dockerImage
  ) {
    plan.push('delete-all');
  }
  return plan;
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

  // Entries are collected into three groups and appended at the end rather than
  // written out as each one is decided: the native route first, the Docker route
  // under it, and everything destructive behind a rule at the bottom. Deciding
  // them in place is what left a Docker-only row reading "Download only /
  // Delete Docker image / Download and launch natively" - a delete in the middle
  // of the menu, between two entries that belong next to each other, while the
  // other three deletes sat under a rule at the end.
  // Four groups: the row's own log at the top, then the native route, then the
  // Docker one, then everything destructive behind a rule at the bottom.
  const groups = { log: [], native: [], docker: [], danger: [] };
  let group = 'native';

  const plan = new Set(menuPlan(row));

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
    // Destructive goes to the bottom whichever route raised it - a delete is a
    // delete, and grouping it with its route would put one above the rule.
    groups[danger ? 'danger' : group].push(button);
  };

  // The row's log, where there is one. A version that is downloading has it on
  // the button in front of this menu, but an installed one and a running one had
  // no route to their own output at all: the only way in was to have been
  // watching when it happened, and the panel is closed the rest of the time.
  const logKey = streamKeyOf(row);
  if (plan.has('log')) {
    group = 'log';
    item('terminal', 'View log', async () => {
      watch(logKey, row.name);
    });
    group = 'native';
  }

  // Within a group: the entry that runs the version first, the fetch-only one
  // under it. The heavier action is the one being looked for - fetch-only is the
  // "fill the shelf now, use it later" variant of it.
  group = 'native';

  // The row's button is Docker, so the native launcher has to be somewhere -
  // including on a version that is not downloaded yet, which is most of them.
  // Not offered while the container is up: "Launch natively as well" below is
  // that entry.
  // Not when the vendor has stopped serving it: "anyway" is for a launch that
  // might work, and this one cannot be fetched at all. An already-downloaded copy
  // is a different matter - that one is on disk and still starts.
  if (plan.has('launch-anyway')) {
    const label = row.installed
      ? 'Launch natively anyway'
      : 'Download and launch natively';
    item('play', label, async () => {
      const { stream } = await post('/api/launch', {
        selector,
        ...launchOptions(),
        ...streamBody(row),
      });
      watch(stream, row.name, { auto: true });
    });
  }

  // Both ways of running this version are available and only one of them has the
  // row's button, so the other cannot be a dead end.
  if (plan.has('launch-as-well')) {
    item('play', 'Launch natively as well', async () => {
      const { stream } = await post('/api/launch', {
        selector,
        ...launchOptions(),
        ...streamBody(row),
      });
      watch(stream, row.name, { auto: true });
    });
  }

  // Nothing to download when the catalog has no build of this version for this
  // machine, or when the vendor has stopped serving the one it has: the entry
  // used to be there and the job it started died in the log.
  if (plan.has('download-only')) {
    item('download', 'Download only', async () => {
      const { stream } = await post('/api/install', {
        selector,
        ...streamBody(row),
      });
      watch(stream, row.name, { auto: true });
    });
  }

  // Docker, if this milestone has a Linux build to put in a container. Every
  // action is keyed by that Linux revision, which is the mismatch that used to
  // leave a running container looking stopped: the shelf compared it against the
  // revision this host installs natively, and the two are never the same.
  group = 'docker';
  const docker = row.dockerSelector;
  if (row.dockerAvailable) {
    if (row.dockerRunning) {
      // Only when the native window has taken the row's Open button: both
      // routes are up, and the container's desktop cannot be the same button.
      // Otherwise this entry and that button read word for word the same.
      if (plan.has('open-desktop')) {
        item('link', 'Open the desktop', async () => {
          openDesktop(row);
        });
      }
      // Last in its group: it is the way out of the route, not a way into it.
      // Not while a stop is already on its way, which is the one docker job that
      // can be running with the container still up.
      if (plan.has('stop-container')) {
        item('stop', 'Stop the container', async () => {
          const { stream } = await post('/api/docker', {
            selector: docker,
            action: 'stop',
            ...streamBody(row),
          });
          watch(stream, row.name, { auto: true });
        });
      }
    } else {
      // Not when the row's own button already is this: on a Docker-first row the
      // two read word for word the same, which is one entry too many.
      if (plan.has('docker-launch')) {
        item(
          'cube',
          row.dockerImage
            ? 'Launch in Docker (noVNC)'
            : 'Get & launch in Docker',
          async () => {
            const { stream } = await post('/api/docker', {
              selector: docker,
              action: 'start',
              screen: desktopScreen(),
              ...streamBody(row),
            });
            watch(stream, row.name, { auto: true });
          },
        );
      }
      // The other half of "Download only": fill the shelf now, use it later. An
      // image build is minutes, and having to sit through them at the moment
      // you wanted a browser is the thing this avoids.
      // The cube rather than a download arrow, which is the glyph the native
      // fetch above wears: the two entries sat one under the other reading
      // "Download only" and "Get the container only" behind the same icon.
      if (plan.has('docker-build')) {
        item('cube', 'Get the container only', async () => {
          const { stream } = await post('/api/docker', {
            selector: docker,
            action: 'build',
            ...streamBody(row),
          });
          watch(stream, row.name, { auto: true });
        });
      }
      // Not destructive - the image is replaced, the profile volume is kept - so
      // it belongs with the route's other builds rather than under the rule.
      if (plan.has('docker-rebuild')) {
        item('reset', 'Rebuild image', async () => {
          const go = await askConfirm({
            title: `Rebuild the Docker image for ${row.name}?`,
            body:
              'The image is built again from scratch, which takes several ' +
              "minutes. The container's profile is kept, so cookies and logins " +
              'survive. Worth doing when a fix has landed in the image itself.',
            label: 'Rebuild',
          });
          if (!go) return;
          const { stream } = await post('/api/docker', {
            selector: docker,
            action: 'rebuild',
            screen: desktopScreen(),
            ...streamBody(row),
          });
          watch(stream, row.name, { auto: true });
        });
      }
    }
  }

  // Everything below here is destructive and lands under the rule in the order
  // it is written: the profile, then the build, then the image. Native first
  // because a row that has both is a row whose button is native.
  if (plan.has('reset')) {
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
        const { stream } = await post('/api/clean', {
          selector,
          ...streamBody(row),
        });
        watch(stream, row.name, { auto: true });
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
        const { stream } = await post('/api/remove', {
          selector,
          ...streamBody(row),
        });
        watch(stream, row.name, { auto: true });
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
        const { stream } = await post('/api/remove', {
          selector,
          withProfile: true,
          ...streamBody(row),
        });
        watch(stream, row.name, { auto: true });
      },
      true,
    );
  }

  // The Docker half of "Reset profile" above. Its profile is a volume, and the
  // container has to let go of it first - which is what the CLI's `clean` does.
  if (plan.has('docker-reset')) {
    item(
      'reset',
      "Reset the container's profile",
      async () => {
        const go = await askConfirm({
          title: `Reset the container's profile for ${row.name}?`,
          body:
            'Cookies, logins and storage inside the container are deleted, and ' +
            'the container is taken down to release them. The image stays, so ' +
            'the next launch starts clean without a rebuild. The native build ' +
            'and its own profile are untouched.',
          label: 'Reset profile',
        });
        if (!go) return;
        const { stream } = await post('/api/docker', {
          selector: docker,
          action: 'clean',
          ...streamBody(row),
        });
        watch(stream, row.name, { auto: true });
      },
      true,
    );
  }

  if (plan.has('delete-image')) {
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
        const { stream } = await post('/api/docker', {
          selector: docker,
          action: 'purge',
          ...streamBody(row),
        });
        watch(stream, row.name, { auto: true });
      },
      true,
    );
  }

  // The pair native has had all along: "Delete browser" and "Delete browser and
  // profile". The Docker side had only the first, so the volume could be reached
  // by "Delete everything" or not at all.
  if (plan.has('delete-image-both')) {
    const both = row.dockerImage + row.dockerProfileBytes;
    item(
      'trash',
      `Delete Docker image and profile (${mb(both)})`,
      async () => {
        const go = await askConfirm({
          title: `Delete the Docker image and profile for ${row.name}?`,
          body:
            `Frees up to ${mb(both)}, less whatever image layers other ` +
            'EngineShelf images share. Cookies and logins inside the container ' +
            'are gone for good, and building the image again takes several ' +
            'minutes. The native build and its own profile are untouched.',
          label: 'Delete both',
        });
        if (!go) return;
        const { stream } = await post('/api/docker', {
          selector: docker,
          action: 'purge',
          withProfile: true,
          ...streamBody(row),
        });
        watch(stream, row.name, { auto: true });
      },
      true,
    );
  }

  // Both routes are on disk, so there is a "get this version off my machine"
  // that neither of the deletes above is: each of them leaves the other route's
  // gigabyte behind, and reclaiming the lot meant two trips through this menu
  // and two confirmations.
  if (plan.has('delete-all')) {
    const everything =
      row.sizeBytes + row.profileBytes + row.dockerImage + row.dockerProfileBytes;
    item(
      'trash',
      `Delete everything (${mb(everything)})`,
      async () => {
        const go = await askConfirm({
          title: `Delete every copy of ${row.name}?`,
          body:
            `The downloaded build, its profile, the Docker image and the ` +
            `container's profile volume - ${mb(everything)}, less whatever image ` +
            'layers other EngineShelf images share. Cookies and logins for this ' +
            'version are gone for good on both routes, and building the image ' +
            'again takes several minutes.',
          label: 'Delete everything',
        });
        if (!go) return;
        // Both against the same log, which is what shows them running side by
        // side with a control each.
        const [native, image] = await Promise.allSettled([
          post('/api/remove', {
            selector,
            withProfile: true,
            ...streamBody(row),
          }),
          post('/api/docker', {
            selector: docker,
            action: 'purge',
            withProfile: true,
            ...streamBody(row),
          }),
        ]);
        const failed = [native, image].find((one) => one.status === 'rejected');
        if (failed) {
          showJobFailure(row.name, failed.reason.message);
          return;
        }
        watch(streamKeyOf(row), row.name, { auto: true });
      },
      true,
    );
  }

  // One rule, and only when there is something on each side of it. A menu of
  // nothing but deletes - an installed version with no container route - would
  // otherwise open with a line across the top.
  const safe = [...groups.native, ...groups.docker];
  let written = false;
  for (const part of [groups.log, safe, groups.danger]) {
    if (!part.length) continue;
    if (written) menu.append(document.createElement('hr'));
    for (const button of part) menu.append(button);
    written = true;
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
    running.find((job) => job.stream === watchKey) ||
    running.find((job) => job.kind !== 'launch') ||
    running[0] ||
    null
  );
}

// How many running jobs the bar shows before the rest go behind "+N more". Two
// fits beside the path and the buttons on a 44px strip; three does not.
const BAR_JOBS = 2;

function renderStatusBar() {
  const line = $('job-line');
  line.textContent = '';

  const running = state ? state.jobs.filter((job) => job.kind !== 'doctor') : [];
  const doctors = state ? state.jobs.filter((job) => job.kind === 'doctor') : [];
  // Whatever the log panel is watching goes first, then everything else in the
  // order the manager has it. A dependency install is work too, and lands after.
  const ordered = [
    ...running.filter((job) => job.stream === watchKey),
    ...running.filter((job) => job.stream !== watchKey),
    ...doctors,
  ];

  const shown = ordered.slice(0, BAR_JOBS);
  line.classList.toggle('many', shown.length > 1);

  const others = ordered.length - shown.length;
  const more = $('job-more');
  more.hidden = others < 1;
  more.textContent = others < 1 ? '' : `+${others} more`;
  more.title = others < 1 ? '' : 'Show the other running jobs';

  if (!shown.length) {
    // A container is not a job: the launcher exits the moment the desktop
    // answers, so with one running and nothing else happening this bar used to
    // read "Nothing running" underneath an open browser.
    const containers = state
      ? asArray(state.docker && state.docker.containers).length
      : 0;
    line.append(
      jobEntry({
        state: containers ? 'running' : 'idle',
        title: !containers
          ? 'Ready'
          : containers === 1
            ? '1 version running in Docker'
            : `${containers} versions running in Docker`,
        detail: containers ? 'nothing else in progress' : 'Nothing running',
      }),
    );
    return;
  }

  for (const job of shown) {
    const info = jobInfo.get(job.id) || null;
    const open = job.kind === 'launch' && info && info.phase === 'open';
    line.append(
      jobEntry({
        state: open ? 'running' : 'working',
        title: jobTitle(job, info),
        // The byte counts and time left when curl is reporting them, the step's
        // own name when it has nothing to report.
        detail: open ? 'running' : (info && info.detail) || `${workWord(job, info)}…`,
        percent: open ? null : info ? info.percent : null,
        bar: !open,
      }),
    );
  }
}

function jobEntry({ state: mark, title, detail, percent = null, bar = false }) {
  const one = document.createElement('div');
  one.className = 'job-one';

  const dot = document.createElement('span');
  dot.className = 'dot';
  dot.dataset.state = mark;

  const name = document.createElement('span');
  name.className = 'job-title';
  name.textContent = title;
  name.title = title;

  const said = document.createElement('span');
  said.className = 'job-detail mono';
  said.textContent = detail;

  one.append(dot, name, said);

  if (bar) {
    const meter = document.createElement('span');
    meter.className = 'job-bar';
    meter.classList.toggle('indeterminate', percent == null);
    const fill = document.createElement('i');
    if (percent != null) fill.style.width = `${percent}%`;
    meter.append(fill);
    one.append(meter);
  }
  return one;
}

// /api/state lists the running jobs but not their output, and the output is
// where the phase and the meter are. One read per running job per refresh.
async function sampleJobs() {
  const running = state
    ? state.jobs.filter((job) => job.kind !== 'doctor')
    : [];
  await Promise.all(
    running.map(async (job) => {
      // Every running job, the watched log's included: /api/job/<id> returns
      // the lines that job wrote and no others, which is the only honest source
      // once two of them can be writing to one log at the same time.
      try {
        noteJob(job, (await api(`/api/job/${job.id}`)).output);
      } catch {
        /* the next refresh will try again */
      }
    }),
  );
  for (const id of [...jobInfo.keys()]) {
    const kept = watchKey ? logStreams.get(watchKey) : null;
    const held =
      kept &&
      [kept.job, ...asArray(kept.jobs)].some((job) => job && job.id === id);
    if (!held && !running.some((job) => job.id === id)) jobInfo.delete(id);
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
   One log per target, not one per job. Several versions can be busy at once - two
   browsers open while a third downloads - so the panel is a switcher, and the
   thing it switches between is a *stream*: everything that has ever run against
   one row of the shelf, in order, with a divider between runs.

   That is the difference from what this was. Tabs used to be jobs, so cancelling
   a download and starting it again opened a second tab and left the first one
   holding the only record of what went wrong; six of them fitted and the seventh
   pushed the oldest off the end; and none of it outlived a reload, because the
   strip was built out of a Map in this file. The server owns the streams now, the
   page reads the list off the state document, and closing a tab hides it here
   rather than throwing anything away. */

// key -> {key, label, lines: [], total, job, jobs, updated, local, status}
//   lines  what this window holds of the stream, as text
//   total  the absolute line number after the last one it holds
//   jobs   everything still running on it, which can be more than one
const logStreams = new Map();
let watchKey = null; // stream shown in the panel
let logTimer = null;
let logBusy = false; // a read of the watched stream is in flight
let logFailures = 0; // consecutive failed reads of it

const LOG_WATCH_KEY = 'engineshelf.logWatch';
const LOG_AUTO_KEY = 'engineshelf.logAuto';
const LOG_HIDDEN_KEY = 'engineshelf.logHidden';

// Whether the panel is allowed to open itself. It does when work starts - that
// is what it is for - and stops the moment somebody closes it, until they ask
// for it again.
//
// Remembered, because "until they ask for it again" has to outlive a reload. The
// panel being open is *not* remembered: the app always opens with it shut, and
// the first thing that runs brings it up.
let logAuto = readStored(LOG_AUTO_KEY) !== '0';

// Which log a row's jobs write to. Not the selector: a version's native build and
// its container are two ways of running the same row, addressed by two different
// selectors - Chromium's container runs a Linux revision this host never installs
// - and filing them apart gave one version two logs. The catalog id is the one
// thing that is the same for both and does not change when a milestone resolves
// to a revision.
const streamKeyFor = (engine, id) =>
  `${engine}:${String(id ?? '?')
    .replace(/[^0-9A-Za-z.:_-]/g, '-')
    .slice(0, 60)}`;

const streamKeyOf = (row) =>
  streamKeyFor(row.engine, (row.raw && row.raw.id) ?? row.selector);

// Spread into the body of anything that starts a job. The server files output
// under this and hands the key back, so nothing here has to guess it.
const streamBody = (row) => ({
  stream: streamKeyOf(row),
  streamLabel: row.name,
});

// `byUser` for the cross and the Show log button - the two ways somebody says
// what they want. Everything else opens it without claiming to know.
function setLogOpen(open, byUser = false) {
  $('log-panel').hidden = !open;
  $('log-btn-label').textContent = open ? 'Hide log' : 'Show log';
  if (byUser) {
    logAuto = open;
    writeStored(LOG_AUTO_KEY, open ? '1' : '0');
  }
  if (!open) {
    stopLogPump();
    return;
  }
  // The strip measures itself to decide what fits, which it cannot do until the
  // panel it lives in has a width - so opening is what draws it.
  renderLogTabs();
  renderLog();
  pumpLog();
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

  // A window that shrinks below what the stored height allows, and a strip whose
  // fold moves because the panel got narrower.
  window.addEventListener('resize', () => {
    const now = out.getBoundingClientRect().height;
    if (now > logHeightMax()) setLogHeight(logHeightMax(), false);
    if (!panel.hidden) renderLogTabs();
  });
})();

/* ---------- the stream list ---------- */

function makeStream(key, label) {
  const had = logStreams.get(key);
  if (had) {
    if (label) had.label = label;
    return had;
  }
  const stream = {
    key,
    label: label || key,
    lines: [],
    total: 0,
    job: null,
    jobs: [],
    updated: 0,
    local: false,
    status: '',
  };
  logStreams.set(key, stream);
  return stream;
}

// The manager's list, merged in rather than swapped for: a stream being read
// right now already holds lines this does not carry.
function noteStreams(list) {
  const seen = new Set();
  for (const entry of asArray(list)) {
    if (!entry || !entry.key) continue;
    seen.add(entry.key);
    const stream = makeStream(entry.key, entry.label);
    stream.job = entry.job || null;
    stream.jobs = asArray(entry.jobs);
    stream.updated = entry.updated || stream.updated;
    // A page that has just loaded knows the size of every log and the contents
    // of none, so the one it opens asks from the start.
    if (!stream.lines.length) stream.total = 0;
  }
  // Evicted by a manager that has been up a week - and with the stream gone,
  // the note saying its tab was put away is worth nothing either.
  for (const key of [...logStreams.keys()]) {
    const stream = logStreams.get(key);
    if (!stream.local && !seen.has(key)) logStreams.delete(key);
  }
  let pruned = false;
  for (const key of Object.keys(hidden)) {
    if (!logStreams.has(key)) {
      delete hidden[key];
      pruned = true;
    }
  }
  if (pruned) saveHidden();
  if (watchKey && !logStreams.has(watchKey)) watchKey = null;

  // An open panel with a log on the strip and nothing picked is a dead end, and
  // it is where a tab coming back out of hiding lands.
  if (!$('log-panel').hidden && !watchKey) {
    const first = tabKeys()[0];
    if (first) {
      watchKey = first;
      writeStored(LOG_WATCH_KEY, first);
      logFailures = 0;
      pumpLog(); // draws the body; renderLogTabs follows from the refresh
      return;
    }
  }

  // Something started on the log this window is showing - most often in the
  // other window onto the same manager. The pump stops when a run ends, so it
  // has to be started again rather than left waiting for a click.
  if (!logTimer && !logBusy && !$('log-panel').hidden && watchKey) {
    const stream = logStreams.get(watchKey);
    if (stream && isRunning(stream)) pumpLog();
  }
}

// The job the shelf's rows are looking at, mapped back to the log it writes to.
const streamOfJob = (job) => (job && job.stream) || null;

// Everything in flight on a log. More than one is ordinary: a version can be
// downloading natively while its container builds, and both write here.
const runningJobs = (stream) =>
  stream ? asArray(stream.jobs).filter((job) => job && job.status === 'running') : [];

// Anything in flight. Not the same as the version being up: see isLive below.
const isRunning = (stream) => runningJobs(stream).length > 0;

// Anything going on at all - a job in flight, a native window open, or a
// container up. This is what decides whether a tab can be closed, because a
// container's job ends as soon as the desktop answers: measured off the job, a
// running container was "idle", offered a cross, and could be closed for good
// while the browser inside it was still on screen.
function isLive(stream) {
  if (isRunning(stream)) return true;
  const live = stream && streamLive.get(stream.key);
  return Boolean(live && (live.running || live.dockerRunning));
}

const endWord = (job) =>
  job.status === 'stopped'
    ? 'stopped'
    : job.status !== 'done'
      ? `failed (exit ${job.code})`
      : // "Docker stop" succeeding means the container is off, and reading that
        // back as "finished" is what made a stopped container and a completed
        // build look like the same outcome.
        job.kind === 'docker' && job.action === 'stop'
        ? 'stopped'
        : 'finished';

const watchedLabel = () => {
  const stream = watchKey ? logStreams.get(watchKey) : null;
  if (stream) return stream.label;
  // "No job yet" would be a claim about the manager's work, and against one too
  // old to keep logs the page has no idea. The status line says which it is.
  if (!managerLogs) return '';
  // Counted against what is on the strip, not against what the manager holds: a
  // panel whose every tab has been put away read "pick a log above" over an
  // empty strip.
  return tabsShown.length ? '' : 'No job yet';
};

/* ---------- closing a tab ----------
   Closing is not throwing the log away. The job keeps running, the manager keeps
   writing, and the tab comes back the next time something runs against that
   version - with everything that was there before it still above the divider.

   What is remembered is the job that was newest on the stream when it was closed,
   so "something ran against it again" means a *different job*, not another line
   from the run that was already going. Measured in lines, closing the tab of a
   live download was a button that undid itself before the finger was off it -
   which is why the cross used to be withheld from a tab with anything going on,
   and withholding it was the wrong half of the problem to fix. */

let hidden = {};

(function readHidden() {
  try {
    const held = JSON.parse(readStored(LOG_HIDDEN_KEY) || '{}');
    if (held && typeof held === 'object') hidden = held;
  } catch {
    hidden = {};
  }
})();

const saveHidden = () => writeStored(LOG_HIDDEN_KEY, JSON.stringify(hidden));

// The job a stream is on, as the closed-set records it. '' for a stream nothing
// has run on yet, which any first job then differs from.
const jobMark = (stream) => (stream.job ? String(stream.job.id) : '');

function isHidden(stream) {
  const at = hidden[stream.key];
  if (at === undefined) return false;
  if (jobMark(stream) !== at) {
    delete hidden[stream.key];
    saveHidden();
    return false;
  }
  return true;
}

function hideStream(key) {
  const stream = logStreams.get(key);
  if (!stream) return;
  if (stream.local) {
    // A failure this page wrote itself: there is no stream on the manager behind
    // it and nothing will ever be appended, so hiding it is closing it.
    logStreams.delete(key);
  } else {
    hidden[key] = jobMark(stream);
    saveHidden();
  }
  if (watchKey === key) {
    watchKey = tabsShown.find((other) => other !== key) || null;
    writeStored(LOG_WATCH_KEY, watchKey || '');
    logFailures = 0;
  }
  renderLogTabs();
  renderLog();
  pumpLog();
}

function hideFinishedStreams() {
  for (const stream of [...logStreams.values()]) {
    if (isLive(stream)) continue;
    if (stream.local) logStreams.delete(stream.key);
    else hidden[stream.key] = jobMark(stream);
  }
  saveHidden();
  if (!watchKey || !logStreams.has(watchKey) || hidden[watchKey] !== undefined) {
    watchKey = [...logStreams.values()].find(isLive)?.key || null;
    writeStored(LOG_WATCH_KEY, watchKey || '');
  }
  renderLogTabs();
  renderLog();
  pumpLog();
}

/* ---------- tabs ----------
   The strip is a fixed width, so the tabs that do not fit go behind a +N chip
   rather than scrolling out of reach or - as they used to - pushing the oldest
   one off the end and out of existence. Order is this window's own: newest
   stream on the left, and anything picked out of the overflow list moves to the
   front. */

const tabOrder = []; // stream keys, left to right
let tabsShown = []; // what the last render actually put on the strip

// stream key -> {running, dockerRunning}: whether that version has a native
// window up, and whether its container is up. Read off the shelf's own rows,
// because the job cannot say. A container's job exits the moment the desktop
// answers - that is what "Docker start" *is* - so its log's last job has been
// "done" for as long as the container has been running, and the tab wore a tick
// beside a native browser that was pulsing away next to it.
const streamLive = new Map();

function noteLiveRows(rows) {
  streamLive.clear();
  for (const row of rows) {
    const key = streamKeyOf(row);
    const had = streamLive.get(key);
    streamLive.set(key, {
      running: Boolean(row.running) || Boolean(had && had.running),
      dockerRunning:
        Boolean(row.dockerRunning) || Boolean(had && had.dockerRunning),
      // What it takes to stop that container from the panel. Not the row's own
      // selector: Chromium's container runs a Linux revision this host never
      // installs, and that is the one the launcher answers to.
      dockerSelector: row.dockerSelector || (had && had.dockerSelector) || null,
      name: row.name || (had && had.name) || '',
    });
  }
}

function tabKeys() {
  const live = new Set();
  for (const stream of logStreams.values()) {
    if (!isHidden(stream)) live.add(stream.key);
  }
  for (const key of [...tabOrder]) {
    if (!live.has(key)) tabOrder.splice(tabOrder.indexOf(key), 1);
  }
  // Newest first, and the order otherwise left alone: a strip that re-sorts
  // itself every second is a strip you cannot click.
  for (const key of live) {
    if (!tabOrder.includes(key)) tabOrder.unshift(key);
  }
  return tabOrder;
}

/* ---------- what a tab says it is doing ----------
   A coloured dot cannot tell downloading from unpacking from up from finished
   from failed - and with a dozen tabs on the strip that is exactly what has to
   be readable at a glance. So each tab carries the glyph for its own state, and
   the ones that mean "still going" move. */

// What one job in flight looks like.
function busyMark(job) {
  const info = jobInfo.get(job.id) || null;
  const phase = info ? info.phase : null;
  if (phase === 'downloading') return { glyph: 'download', state: 'downloading' };
  if (phase === 'open') return { glyph: 'play', state: 'running' };
  // Nothing downloading and nothing up, so the glyph says which kind of work it
  // is instead: an unpack, a delete, a profile reset, a container starting.
  if (job.kind === 'remove') return { glyph: 'trash', state: 'working' };
  if (job.kind === 'clean') return { glyph: 'reset', state: 'working' };
  if (job.kind === 'docker') return { glyph: 'cube', state: 'working' };
  return { glyph: 'spinner', state: 'working' };
}

function tabMark(stream) {
  const live = streamLive.get(stream.key) || null;
  const job = stream.job;

  // Work in progress speaks first: a download or an unpack is what the tab is
  // there for, and it is happening whatever else is already up. With two of them
  // going the download wins - it is the one with a number on it.
  const busy = runningJobs(stream).map(busyMark);
  if (busy.length)
    return busy.find((mark) => mark.state === 'downloading') || busy[0];

  // Nothing in flight, but the version may well be up. Both routes get the same
  // colour and the same beat - up is up - and their own glyph, because which one
  // is up is the thing you came to the strip to find out.
  if (live && live.running) return { glyph: 'play', state: 'running' };
  if (live && live.dockerRunning) return { glyph: 'cube', state: 'running' };

  if (!job) return { glyph: 'terminal', state: 'idle' };
  if (job.status === 'stopped') return { glyph: 'stop', state: 'idle' };
  if (job.status !== 'done') return { glyph: 'warn', state: 'bad' };
  // A stop that succeeded is not "finished", it is "off" - which is the same
  // thing the square already says over a native browser that was told to close.
  // Both wore the tick before this, and only one of them deserved it.
  if (job.kind === 'docker' && job.action === 'stop')
    return { glyph: 'stop', state: 'idle' };
  return { glyph: 'ok', state: 'done' };
}

// The one sentence for what a log's version is doing: the tab's tooltip and the
// status beside the panel's title are the same answer in two places.
function streamState(stream) {
  const live = streamLive.get(stream.key) || null;
  const busy = runningJobs(stream);
  if (busy.length > 1)
    return busy.map((job) => workWord(job, jobInfo.get(job.id) || null)).join(' + ');
  if (busy.length === 1) {
    const job = busy[0];
    const info = jobInfo.get(job.id) || null;
    if (info && info.phase === 'open') return 'running';
    return info && info.detail
      ? `${workWord(job, info)} · ${info.detail}`
      : `${workWord(job, info)}…`;
  }
  const job = stream.job;
  if (live && live.running && live.dockerRunning)
    return 'running natively and in Docker';
  if (live && live.running) return 'running';
  if (live && live.dockerRunning) return 'running in Docker';
  if (!job) return stream.status || 'nothing running';
  return endWord(job);
}

const tabTitle = (stream) => `${stream.label} — ${streamState(stream)}`;

function markSpan(mark) {
  const glyph = document.createElement('span');
  glyph.className = 'mark';
  glyph.dataset.state = mark.state;
  glyph.innerHTML = icon(mark.glyph);
  return glyph;
}

const stateMark = (stream) => markSpan(tabMark(stream));

function makeTab(stream) {
  const tab = document.createElement('div');
  tab.className = `log-tab${stream.key === watchKey ? ' is-on' : ''}`;

  const pick = document.createElement('button');
  pick.type = 'button';
  pick.className = 'pick';

  const name = document.createElement('span');
  name.className = 'name';
  name.textContent = stream.label;

  pick.append(stateMark(stream), name);
  pick.title = tabTitle(stream);
  if (stream.key !== watchKey) pick.onclick = () => watch(stream.key);
  tab.append(pick);

  // On every tab, including one with a download in flight or a browser up: the
  // strip is the thing being tidied, and closing a tab stops and deletes nothing.
  const shut = document.createElement('button');
  shut.type = 'button';
  shut.className = 'x';
  shut.innerHTML = icon('x');
  shut.title = closeHint(stream);
  shut.setAttribute('aria-label', `Close the log for ${stream.label}`);
  shut.onclick = (event) => {
    event.stopPropagation();
    hideStream(stream.key);
  };
  tab.append(shut);
  return tab;
}

// Said differently over something still going: there the tab is being put away
// out from under work that carries on without it, and the status bar is where it
// carries on being visible.
const closeHint = (stream) =>
  isLive(stream)
    ? `Close this log. ${stream.label} carries on - the status bar keeps it, and ` +
      'the tab comes back the next time something runs against this version.'
    : `Close this log. ${stream.label} keeps everything it has written; the tab ` +
      'comes back if something runs against this version again.';

function renderLogTabs() {
  const tabs = $('log-tabs');
  tabs.textContent = '';
  // The overflow list is anchored to a chip this is about to rebuild, so it
  // cannot outlive it.
  if (openMenu && openMenu.dataset.owner === OVERFLOW_OWNER) closePopovers();

  // Whatever is running is a stream whether or not the state document has been
  // read since it started - a job the other window began, most often.
  // Grouped, because one version can have two jobs going at once.
  const seeded = new Map();
  for (const job of state ? state.jobs : []) {
    if (!job.stream) continue;
    if (!seeded.has(job.stream)) seeded.set(job.stream, []);
    seeded.get(job.stream).push(job);
  }
  for (const [key, jobs] of seeded) {
    const stream = makeStream(key, null);
    stream.jobs = jobs;
    stream.job = jobs[jobs.length - 1];
  }

  const keys = tabKeys();
  // With one log there is nothing to switch between, so it reads as a title.
  const single = keys.length < 2;
  $('log-title').hidden = !single;
  $('log-title').textContent = single ? watchedLabel() : '';
  tabs.hidden = single;
  // Before anything is measured: it is what frees the head's spare room up for
  // the strip to be measured against.
  $('log-panel').classList.toggle('has-tabs', !single);
  $('log-clear').hidden =
    keys.filter((key) => !isLive(logStreams.get(key))).length < 2;
  if (single) {
    tabsShown = keys.slice();
    return;
  }
  // A strip with no width cannot work out what fits. setLogOpen draws it again
  // the moment the panel is up.
  if ($('log-panel').hidden) {
    tabsShown = keys.slice();
    return;
  }

  const room = tabs.clientWidth;
  const built = keys.map((key) => makeTab(logStreams.get(key)));
  for (const tab of built) tabs.append(tab);

  // Measured rather than counted: tabs are as wide as the names on them, and the
  // strip is as wide as the panel head leaves it.
  const widths = built.map((tab) => tab.offsetWidth + TAB_GAP);
  let fits = keys.length;
  if (widths.reduce((sum, width) => sum + width, 0) > room) {
    // The chip has to fit too, and it is only there if something overflows.
    let used = TAB_CHIP;
    fits = 0;
    while (fits < keys.length && used + widths[fits] <= room) {
      used += widths[fits];
      fits += 1;
    }
    fits = Math.max(1, fits);
  }

  // The tab being read is never the one that gets folded away: if it has drifted
  // past the fold it comes to the front, the same move picking it out of the
  // overflow list makes. One pass only - it is at index 0 the second time.
  if (watchKey && keys.indexOf(watchKey) >= fits) {
    toFront(watchKey);
    renderLogTabs();
    return;
  }

  tabsShown = keys.slice(0, fits);
  for (let at = fits; at < built.length; at += 1) built[at].remove();
  if (fits < keys.length) tabs.append(overflowChip(keys.slice(fits)));
}

const TAB_GAP = 5; // matches the strip's gap in styles.css
const TAB_CHIP = 54; // what the +N chip needs, gap included

function toFront(key) {
  const at = tabOrder.indexOf(key);
  if (at < 0) return;
  tabOrder.splice(at, 1);
  tabOrder.unshift(key);
}

// The tabs that did not fit. Picking one moves it to the front of the strip,
// which folds the last one that did fit into this list in its place - so
// everything stays reachable in one press and the strip never scrolls.
function overflowChip(rest) {
  const chip = document.createElement('div');
  chip.className = 'log-more';

  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'pick';
  button.textContent = `+${rest.length}`;
  button.title = `${rest.length} more log${rest.length === 1 ? '' : 's'}`;
  button.setAttribute('aria-label', `Show ${rest.length} more logs`);
  button.onclick = (event) => {
    event.stopPropagation();
    const again = openMenu && openMenu.dataset.owner === OVERFLOW_OWNER;
    closePopovers();
    if (again) return;
    openMenu = openOverflowMenu(button, rest);
  };

  chip.append(button);
  return chip;
}

const OVERFLOW_OWNER = 'log-overflow';

// The strip clips whatever is inside it - it has to, or the tabs that were
// folded away would still be on screen - so the list hangs off the panel and is
// lined up with the chip by hand.
function openOverflowMenu(button, rest) {
  const panel = $('log-panel');
  const menu = buildOverflowMenu(rest);
  menu.dataset.owner = OVERFLOW_OWNER;
  panel.append(menu);

  const chip = button.getBoundingClientRect();
  const box = panel.getBoundingClientRect();
  menu.style.left = `${Math.max(
    8,
    Math.min(chip.left - box.left, box.width - menu.offsetWidth - 8),
  )}px`;
  // Upwards without asking: the panel is docked to the bottom of the window, so
  // there is never room below the strip.
  menu.style.bottom = `${box.bottom - chip.top + 6}px`;
  return menu;
}

function buildOverflowMenu(rest) {
  const menu = document.createElement('div');
  menu.className = 'menu log-menu';

  for (const key of rest) {
    const stream = logStreams.get(key);
    if (!stream) continue;

    const row = document.createElement('button');
    row.type = 'button';

    const name = document.createElement('span');
    name.className = 'grow';
    name.textContent = stream.label;

    const shut = document.createElement('span');
    shut.className = 'x';
    shut.setAttribute('role', 'button');
    shut.innerHTML = icon('x');
    shut.title = closeHint(stream);
    shut.onclick = (event) => {
      event.stopPropagation();
      closePopovers();
      hideStream(key);
    };

    row.append(stateMark(stream), name, shut);
    row.title = tabTitle(stream);
    row.onclick = () => {
      closePopovers();
      toFront(key);
      watch(key);
    };
    menu.append(row);
  }
  return menu;
}

/* ---------- watching one ---------- */

function watch(key, label, { auto = false } = {}) {
  if (!key) return;
  makeStream(key, label);
  // Asking to see a log brings its tab back. Without this, "View log" on a row
  // whose tab had been put away opened the log with no tab to return to it by -
  // so viewing a second one read as the first having been closed, when in truth
  // neither had a tab and only the second was on screen.
  if (hidden[key] !== undefined) {
    delete hidden[key];
    saveHidden();
  }
  watchKey = key;
  logFailures = 0;
  writeStored(LOG_WATCH_KEY, key);
  // Work starting asks for the panel; it does not insist. Closed on purpose, it
  // stays closed - the strip, the row and the status bar all still say what is
  // going on, and Show log is one press away.
  if (auto && !logAuto && $('log-panel').hidden) {
    renderLogTabs();
    return;
  }
  if ($('log-panel').hidden) {
    // Opening because someone asked is them asking for it back.
    setLogOpen(true, !auto); // draws the strip and the body, and starts the pump
    return;
  }
  renderLogTabs();
  renderLog();
  pumpLog();
}

/* ---------- reading it ----------
   Line numbers rather than the whole buffer: a container build is thousands of
   lines and this is asked for four times a second while one runs. */

function stopLogPump() {
  clearTimeout(logTimer);
  logTimer = null;
}

async function pumpLog() {
  stopLogPump();
  if ($('log-panel').hidden || !watchKey) return;
  const key = watchKey;
  const stream = logStreams.get(key);
  if (!stream || stream.local) return; // nothing on the manager to read

  let answer;
  logBusy = true;
  try {
    answer = await api(`/api/log/${encodeURIComponent(key)}?since=${stream.total}`);
  } catch (error) {
    logBusy = false;
    if (watchKey !== key) return;
    // Giving up quietly is what made a server-side error look like a job that
    // ran forever: "running…", no log, no clue. One hiccup is worth retrying;
    // four in a row is worth saying out loud.
    if (++logFailures < 4) {
      logTimer = setTimeout(pumpLog, 700);
      return;
    }
    stream.status = 'cannot read this log';
    stream.lines = [
      String(error.message),
      '',
      'The job itself may well be running - this is the manager failing to read its',
      'output. The version list still updates, and the launcher writes its own log',
      'under the EngineShelf home directory.',
    ];
    renderLog();
    return;
  }
  logBusy = false;
  if (watchKey !== key) return;
  logFailures = 0;

  // `first` above what was asked for means the buffer wrapped past it, so what
  // is held here no longer joins onto what came back.
  if (answer.first > stream.total) stream.lines = [];
  stream.lines.push(...asArray(answer.lines));
  stream.total = answer.total;
  stream.label = answer.label || stream.label;
  stream.updated = answer.updated || stream.updated;

  // Progress no longer comes from slicing this buffer: two jobs writing to one
  // log interleave, and the manager knows which lines are whose. sampleJobs reads
  // each running job's own output and fills jobInfo from that.
  const before = runningJobs(stream);
  stream.job = answer.job || null;
  stream.jobs = asArray(answer.jobs);

  renderLog();

  if (isRunning(stream)) {
    renderStatusBar();
    repaintIfMoved();
    logTimer = setTimeout(pumpLog, 700);
    return;
  }
  // The run being watched has ended. Nothing more arrives on this stream until
  // something starts it again, and the refresh loop is what notices that - so
  // the pump stops here rather than idling at 700ms.
  if (before.length) {
    if (stream.job && stream.job.status === 'done')
      flash(`${stream.label} — finished`);
    for (const job of before) jobInfo.delete(job.id);
    refresh();
  }
}

// The title, and one control per thing this version is doing. Its own function
// because the body below is only worth repainting when there is new output, while
// these change with the shelf: a container coming down is not a line in a log, so
// the panel went on reading "running in Docker" over a container that had stopped
// while the tab beside it had already gone grey.
function renderLogHead() {
  const stream = watchKey ? logStreams.get(watchKey) : null;
  const holder = $('log-jobs');
  holder.textContent = '';
  if (logStreams.size < 2) $('log-title').textContent = watchedLabel();

  if (!stream) {
    holder.append(
      statusText(
        !managerLogs
          ? 'this manager is older than the page'
          : tabsShown.length
            ? 'pick a log above'
            : 'output from installs, launches and clean-ups shows up here',
      ),
    );
    return;
  }

  // One per job in flight. Two at once is ordinary - a native download beside a
  // container build - and each gets its own word, its own progress and its own
  // way out, rather than the newest of them taking the whole head.
  const busy = runningJobs(stream);
  for (const job of busy) holder.append(jobPill(job));

  // A container that is up with nothing running against it: there is no job to
  // signal, so the control is the request that stops it.
  const live = streamLive.get(stream.key) || null;
  if (
    live &&
    live.dockerRunning &&
    live.dockerSelector &&
    !busy.some((job) => job.kind === 'docker')
  ) {
    holder.append(containerPill(stream, live));
  }

  if (!holder.childElementCount) holder.append(statusText(streamState(stream)));
}

function statusText(words) {
  const span = document.createElement('span');
  span.className = 'log-status';
  span.textContent = words;
  return span;
}

// The panel is where a long download is actually watched, so it is also where it
// has to be possible to call one off: the row's own button is as often as not
// scrolled out of sight behind it.
function jobPill(job) {
  const info = jobInfo.get(job.id) || null;
  const pill = document.createElement('div');
  pill.className = 'log-job';
  pill.append(markSpan(busyMark(job)));

  const what = document.createElement('span');
  what.className = 'what';
  what.textContent =
    info && info.detail
      ? `${workWord(job, info)} · ${info.detail}`
      : `${workWord(job, info)}…`;
  pill.append(what);
  pill.title = jobTitle(job, info);

  // A delete, a profile reset or a stop is reported rather than offered: see
  // cancellable() for why each of them is over before a button would help.
  if (!cancellable(job)) return pill;

  // A launch job is a download first and a browser afterwards, and the same
  // request ends either - but a cross over a browser that is already up reads as
  // though something were being thrown away. Same two glyphs the rows use: a
  // cross calls off work that has not finished, the square shuts down something
  // that is already up.
  const up = Boolean(info) && info.phase === 'open';
  const going = stopping.has(job.id);
  pill.append(
    stopButton(
      up ? 'stop' : 'x',
      going
        ? 'Waiting for this to stop'
        : up
          ? `Close ${jobName(job)} and everything it started`
          : `Cancel ${jobName(job)}`,
      going,
      () => cancelJob(job.id, `${up ? 'Stopping' : 'Cancelling'} ${jobName(job)}`),
    ),
  );
  return pill;
}

// The container's own entry. Stopping it is a request rather than a signal, and
// it opens a job of its own on this same log - so this control is replaced by
// that job's pill on the next refresh.
function containerPill(stream, live) {
  const pill = document.createElement('div');
  pill.className = 'log-job';
  pill.append(markSpan({ glyph: 'cube', state: 'running' }));

  const what = document.createElement('span');
  what.className = 'what';
  what.textContent = 'running in Docker';
  pill.append(what);
  pill.title = `${stream.label} is running in its Docker container`;

  pill.append(
    stopButton('stop', `Stop the container running ${stream.label}`, false, async () => {
      const button = pill.querySelector('.stop');
      button.disabled = true;
      try {
        await post('/api/docker', {
          selector: live.dockerSelector,
          action: 'stop',
          stream: stream.key,
          streamLabel: live.name || stream.label,
        });
      } catch (error) {
        flash(error.message, 'warn');
        button.disabled = false;
        return;
      }
      refresh();
    }),
  );
  return pill;
}

function stopButton(glyph, title, disabled, handler) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'stop';
  button.innerHTML = icon(glyph);
  button.title = title;
  button.setAttribute('aria-label', title);
  button.disabled = disabled;
  if (!disabled) button.onclick = handler;
  return button;
}

function renderLog() {
  const stream = watchKey ? logStreams.get(watchKey) : null;
  const out = $('log-out');
  const atBottom = out.scrollTop + out.clientHeight >= out.scrollHeight - 20;

  if (!stream) {
    out.textContent = managerLogs
      ? ''
      : 'The manager answering this page was started before the page was updated, ' +
        'so\nit keeps no logs for the page to read.\n\n' +
        'Quit EngineShelf and open it again. Nothing is lost that was not already\n' +
        'gone: the output of a job lives in the process that ran it.';
  } else {
    // curl draws its progress bar with carriage returns; keep only the last frame.
    out.textContent = stream.lines
      .map((line) => line.split('\r').pop())
      .join('\n');
    if (atBottom) out.scrollTop = out.scrollHeight;
  }
  renderLogHead();
}

// A request that failed before a job existed still has to be visible somewhere,
// and the log panel is where the user is already looking for output. Its own
// stream, marked local: there is nothing on the manager to read, and nothing
// will ever be appended to it.
function showJobFailure(title, message) {
  const key = `#${title}`;
  const stream = makeStream(key, title);
  stream.local = true;
  stream.job = null;
  stream.status = 'failed';
  stream.lines = String(message).split('\n');
  delete hidden[key];
  toFront(key);
  watchKey = key;
  writeStored(LOG_WATCH_KEY, key);
  if ($('log-panel').hidden) {
    setLogOpen(true);
    return;
  }
  renderLogTabs();
  renderLog();
}

$('log-close').onclick = () => setLogOpen(false, true);
$('log-clear').onclick = hideFinishedStreams;

$('log-btn').onclick = () => {
  if (!$('log-panel').hidden) {
    setLogOpen(false, true);
    return;
  }
  // Nothing is un-hidden here on purpose. A log you closed is closed: it comes
  // back when something writes to it again, and not because the panel was asked
  // for. Anything that is *still running* was never hidden in the first place -
  // isHidden lets a running stream through - so "show me what is logging" is
  // already what this does.
  if (!watchKey || !logStreams.has(watchKey)) {
    // Whatever is running, else the log something last happened on.
    const job = activeJob();
    watchKey = streamOfJob(job) || tabKeys()[0] || null;
    writeStored(LOG_WATCH_KEY, watchKey || '');
  }
  setLogOpen(true, true);
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


// Undefined from a manager too old to send it at all, which is not the same as
// false: that one is left alone rather than accused of either behaviour.
//
// False now means one thing only. Serving on after the window closes used to be a
// mode you could ask for, and asking for it left the browsers and containers the
// manager had started running with it; the mode is gone, so a manager still
// answering false is one that was started before it went.
function noteAutoQuit(auto, grace) {
  const note = $('foot-keep');
  if (auto !== false) {
    note.hidden = true;
    return;
  }
  if (!note.hidden) return;
  note.hidden = false;
  note.innerHTML = icon('warn');
  note.append('Stays running when closed');
  note.title =
    'This manager goes on serving after its window closes, and leaves the ' +
    'browsers and containers it started running with it. That mode has been ' +
    'removed, so a manager still in it was started before it went. Quit it and ' +
    'open EngineShelf again' +
    (grace
      ? ` - the new one closes everything ${grace}s after its window goes.`
      : '.');
}

/* ---------- controls ---------- */

$('job-more').onclick = () => {
  const job = activeJob();
  if (streamOfJob(job)) watch(job.stream, jobName(job));
  else setLogOpen(true);
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
  // Absent entirely, not merely empty: that is what tells an old manager from a
  // new one with nothing in it yet.
  managerLogs = Array.isArray(next.logs);
  next.logs = asArray(next.logs);
  state = next;
  // The strip is the manager's list of logs, not this window's memory of what it
  // started - which is what makes it survive a reload and show what the other
  // window is doing.
  noteStreams(next.logs);
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
  armSplash();
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

  splashSays('Reading the shelf…');
  await refresh();

  // Which log the panel was on survives a reload; the panel being open does not.
  // The app opens with it shut and the first thing that runs brings it up, so
  // Show log lands on whatever was last being watched rather than on nothing.
  const wanted = readStored(LOG_WATCH_KEY);
  // Not one that was put away: hiding a tab and reloading used to bring its log
  // back as the panel's contents while its tab stayed off the strip.
  if (wanted && logStreams.has(wanted) && !isHidden(logStreams.get(wanted)))
    watchKey = wanted;

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
    // A manager that goes on running when its window closes - along with every
    // browser and container it started. No current one does; one old enough to
    // still be able to is exactly the thing someone needs told before they close
    // the window rather than after.
    noteAutoQuit(beat.autoQuit, beat.grace);
    if (beat.revision === undefined || beat.revision === jobRevision) return;
    const first = jobRevision === null;
    jobRevision = beat.revision;
    if (!first && !popoverOpen() && !document.querySelector('dialog[open]')) {
      refresh();
    }
  }, 1500);
})();
