/* chromium-stack manager — talks to gui/server.py (or gui/server.ps1 on Windows).

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
  theme: '<circle cx="12" cy="12" r="9"/><path d="M12 3a9 9 0 0 0 0 18z" fill="currentColor" stroke="none"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  link: '<path d="M9.5 14.5l5-5"/><path d="M11 7.6l1.4-1.4a3.5 3.5 0 0 1 5 5L16 12.5"/><path d="M13 16.4l-1.4 1.4a3.5 3.5 0 0 1-5-5L8 11.5"/>',
  frame: '<path d="M4 9V5h4"/><path d="M20 9V5h-4"/><path d="M4 15v4h4"/><path d="M20 15v4h-4"/>',
  gpu: '<rect x="5" y="5" width="14" height="14" rx="3"/><rect x="9" y="9" width="6" height="6" rx="1.5"/><path d="M9 2.6V5M15 2.6V5M9 19v2.4M15 19v2.4M2.6 9H5M2.6 15H5M19 9h2.4M19 15h2.4"/>',
  "caret-down": '<path d="M6 9.5l6 6 6-6"/>',
  check: '<path d="M20 6.5L9.5 17 4 11.5"/>',
  search: '<circle cx="11" cy="11" r="6.5"/><path d="M16 16l4.5 4.5"/>',
  x: '<path d="M6 6l12 12M18 6L6 18"/>',
  sort: '<path d="M7 4v16M7 20l-3-3M7 20l3-3"/><path d="M17 20V4M17 4l-3 3M17 4l3 3"/>',
  grid: '<rect x="4" y="4" width="6.5" height="6.5" rx="1.6"/><rect x="13.5" y="4" width="6.5" height="6.5" rx="1.6"/><rect x="4" y="13.5" width="6.5" height="6.5" rx="1.6"/><rect x="13.5" y="13.5" width="6.5" height="6.5" rx="1.6"/>',
  "play-circle": '<circle cx="12" cy="12" r="9"/><path d="M10.3 9.2l4.7 2.8-4.7 2.8z" fill="currentColor" stroke="none"/>',
  dots: '<circle cx="5.5" cy="12" r="1.4" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1.4" fill="currentColor" stroke="none"/><circle cx="18.5" cy="12" r="1.4" fill="currentColor" stroke="none"/>',
  download: '<path d="M12 4v10"/><path d="M8 10.5l4 4 4-4"/><path d="M4.5 18.5h15"/>',
  play: '<path d="M8 5.5l11 6.5-11 6.5z" fill="currentColor" stroke="none"/>',
  stop: '<rect x="6.5" y="6.5" width="11" height="11" rx="2.5"/>',
  reset: '<path d="M20 12a8 8 0 1 1-2.4-5.7"/><path d="M20.5 4v5h-5"/>',
  cube: '<path d="M12 3l8 4.5v9L12 21l-8-4.5v-9z"/><path d="M12 21v-9"/><path d="M4 7.5l8 4.5 8-4.5"/>',
  trash: '<path d="M4.5 7h15"/><path d="M9.5 7V4.8h5V7"/><path d="M6.5 7l1 12.2h9l1-12.2"/>',
  terminal: '<rect x="3" y="4.5" width="18" height="15" rx="2.5"/><path d="M7.5 9.5l3 2.7-3 2.7"/><path d="M12.5 15.5h4"/>',
  empty: '<rect x="3" y="6" width="18" height="14" rx="3"/><path d="M3 10h18"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5.2l3 2"/>',
  "down-circle": '<circle cx="12" cy="12" r="9"/><path d="M12 7.5v8"/><path d="M8.5 12l3.5 3.5 3.5-3.5"/>',
};

const icon = (name) =>
  `<svg class="i" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" ` +
  `stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICONS[name] || ICONS.empty}</svg>`;

function paintIcons(root) {
  for (const holder of (root || document).querySelectorAll("[data-icon]")) {
    holder.innerHTML = icon(holder.dataset.icon);
  }
}

const iconSpan = (name) => {
  const span = document.createElement("span");
  span.innerHTML = icon(name);
  span.style.display = "flex";
  return span;
};

/* ---------- theme ---------- */

const THEME_KEY = "chromiumstack.theme";

function readStored(key) {
  try { return localStorage.getItem(key); } catch { return null; }
}
function writeStored(key, value) {
  try { localStorage.setItem(key, value); } catch { /* private mode: not worth failing over */ }
}

(function bootTheme() {
  const stored = readStored(THEME_KEY);
  if (stored === "light" || stored === "dark") document.documentElement.dataset.theme = stored;
})();

/* ---------- shared state ---------- */

let TOKEN = null;
let state = null;
let openMenu = null;      // the row overflow menu, if one is open
let watching = null;      // job id currently shown in the log panel
let watchedTitle = "";    // its name, kept so a finished job keeps its tab
let pollFailures = 0;     // consecutive failed polls of the watched job
const jobInfo = new Map();    // job id -> {phase, percent, detail} read out of its output
const dropdowns = [];

const view = { filter: "all", query: "", sort: "old", gpu: "auto" };

const stopping = new Set();   // launch jobs the user has asked to stop

const PLATFORM_LABELS = {
  Mac_Arm: "native arm64",
  Mac: "x86_64",
  Linux_x64: "Linux x86_64",
  Win_x64: "Windows x86_64",
};

// What a job is doing, in the words the row and the status bar use. The phase
// read from the output wins; the endpoint that started the job is the fallback.
const WORK_WORD = {
  downloading: "downloading", extracting: "extracting", ready: "starting", open: "running",
  install: "installing", launch: "starting", remove: "removing", clean: "resetting", docker: "docker",
};

const workWord = (job, info) => (info && WORK_WORD[info.phase]) || WORK_WORD[job.kind] || "working";
const capitalise = (word) => word.charAt(0).toUpperCase() + word.slice(1);

// Job labels are built by the server, which only knows the revision it was given;
// the page knows which milestone that is.
function jobName(job) {
  const rows = state ? [...state.versions, ...state.extra] : [];
  const row = rows.find((entry) => String(entry.revision) === String(job.revision));
  if (!row) return job.label;
  return row.milestone && row.milestone !== "?" ? `Chromium ${row.milestone}` : row.version || `r${row.revision}`;
}

function jobTitle(job, info) {
  if (job.kind === "doctor") return job.label;
  const name = jobName(job);
  if (info && info.phase === "open") return name;
  if (info && info.phase === "ready") return `Starting ${name}`;
  if (job.kind === "docker") return `Docker · ${name}`;
  // A launch downloads and unpacks first, so both endpoints read as "Installing".
  if (job.kind === "launch" || job.kind === "install") return `Installing ${name}`;
  return `${capitalise(workWord(job, info))} ${name}`;
}

// The server is the source of truth for what is running, so this survives a reload.
const runningJobFor = (selector) =>
  state.jobs.find((job) => job.kind === "launch" && String(job.revision) === selector);

// Anything else the server is doing to a version: a download, a delete, a profile
// reset, a Docker container coming up. Launches are excluded because a running
// browser gets a Stop button rather than a label.
const busyJobFor = (selector) =>
  state.jobs.find((job) => job.kind !== "launch" && job.kind !== "doctor" &&
                           String(job.revision) === selector);

// Dependency installs are jobs too, filed under the component they are fixing.
// Asking the server rather than remembering locally is what keeps the row honest
// across the four-second refresh, which rebuilds these buttons from scratch.
const runningDoctorJob = (component) =>
  state.jobs.find((job) => job.kind === "doctor" && String(job.revision) === component);

/* ---------- api ---------- */

async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: { "Content-Type": "application/json", "X-ChromiumStack-Token": TOKEN, ...(options.headers || {}) },
  });
  if (!response.ok) {
    const detail = await response.json().catch(() => ({}));
    throw new Error(detail.error || `${response.status} ${response.statusText}`);
  }
  return response.json();
}

const post = (path, body) => api(path, { method: "POST", body: JSON.stringify(body) });

// PowerShell's ConvertTo-Json unrolls collections on their way out of a function:
// an empty list can arrive as null and a one-item list as a bare object. Coercing
// the list-shaped fields once, here, beats guarding every use - and stops one odd
// field from taking the whole page down.
const asArray = (value) => (Array.isArray(value) ? value : value == null ? [] : [value]);

/* ---------- formatting ---------- */

function mb(bytes) {
  if (!bytes) return "0 MB";
  const megabytes = bytes / (1024 * 1024);
  if (megabytes >= 1024) return `${(megabytes / 1024).toFixed(2)} GB`;
  return `${Math.round(megabytes)} MB`;
}

function launchOptions() {
  return {
    url: $("url").value.trim(),
    size: $("size").value.trim(),
    gpu: view.gpu === "auto" ? null : view.gpu === "on",
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
  if (!CURL_CLOCK.test(columns[8]) || !CURL_CLOCK.test(columns[10])) return null;
  return { percent: Number(columns[0]), total: columns[1], done: columns[3], left: columns[10] };
}

// "86.4M" -> bytes. curl writes k/M/G/T suffixes, and nothing for plain bytes.
function curlBytes(text) {
  const found = String(text).match(/^([\d.]+)([kMGT]?)$/);
  if (!found) return null;
  return Number(found[1]) * { "": 1, k: 1024, M: 1024 ** 2, G: 1024 ** 3, T: 1024 ** 4 }[found[2]];
}

// "0:00:11" -> "11s left". A dashed clock means curl has nothing to estimate from.
function curlLeft(text) {
  const found = String(text).match(/^(\d+):(\d\d):(\d\d)$/);
  if (!found) return null;
  const seconds = Number(found[1]) * 3600 + Number(found[2]) * 60 + Number(found[3]);
  if (!seconds) return null;
  if (seconds < 60) return `${seconds}s left`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return seconds % 60 ? `${minutes}m ${seconds % 60}s left` : `${minutes}m left`;
  return `${Math.floor(minutes / 60)}h ${minutes % 60}m left`;
}

// Each line the CLI prints to mark a step, latest one wins.
const PHASE_MARKS = [
  [/^\s*Downloading Chromium\b/, "downloading"],
  [/^\s*Extracting\b/, "extracting"],
  [/\bready\.\s*$/, "ready"],
  [/^\s*>\s+Chromium\b/, "open"],
];

function readJob(output) {
  // Every meter redraw is a carriage-return frame; only the last frame of a line
  // still says anything true.
  const frames = String(output || "").split("\n").map((line) => line.split("\r").pop());

  const info = { phase: null, percent: null, detail: null };
  for (const frame of frames) {
    for (const [pattern, name] of PHASE_MARKS) {
      if (pattern.test(frame)) { info.phase = name; break; }
    }
  }
  if (info.phase !== "downloading") return info;

  for (let index = frames.length - 1; index >= 0; index--) {
    const meter = meterFrom(frames[index]);
    if (meter) {
      const done = curlBytes(meter.done);
      const total = curlBytes(meter.total);
      info.percent = Math.min(100, meter.percent);
      info.detail = [done != null && total ? `${mb(done)} / ${mb(total)}` : null, curlLeft(meter.left)]
        .filter(Boolean).join(" · ") || null;
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
  { id: "era-1", label: "2017 – 2019", blurb: "the hard floors — kiosks, old WebViews", until: 2019 },
  { id: "era-2", label: "2020 – 2021", blurb: "flexbox gap, aspect-ratio, :is()", until: 2021 },
  { id: "era-3", label: "2022 – 2023", blurb: "container queries, :has(), nesting", until: 2023 },
  { id: "era-4", label: "2024 – today", blurb: "controls for bisecting", until: 9999 },
];

// Milestones roughly bracket the same years, and cover rows whose note has no year.
const MILESTONE_YEARS = [[76, 2019], [95, 2021], [120, 2023]];

function yearOf(row) {
  const stamped = String(row.note || "").match(/^\s*(\d{4})\./);
  if (stamped) return Number(stamped[1]);
  const milestone = Number(row.milestone);
  if (!Number.isFinite(milestone)) return null;
  for (const [ceiling, year] of MILESTONE_YEARS) if (milestone <= ceiling) return year;
  return 2024;
}

const eraFor = (row) => {
  const year = yearOf(row);
  return year === null ? null : ERAS.find((era) => year <= era.until);
};

/* ---------- shaping a catalog row for the shelf ---------- */

function decorate(row) {
  const selector = row.revision == null ? null : String(row.revision);
  const version = row.version || (selector ? `r${selector}` : "?");
  const milestone = row.milestone && row.milestone !== "?" ? row.milestone : null;
  const raw = row.note || "";

  // Notes name the features in backticks; those double as the row's tags, so the
  // shelf gains a scannable index without a second column in catalog.tsv.
  const tags = [...raw.matchAll(/`([^`]+)`/g)].map((match) => match[1]).slice(0, 3);
  const note = raw.replace(/^\s*\d{4}\.\s*/, "").replace(/`/g, "");

  const rosetta = row.platformDir === "Mac" && state.arch === "arm64";
  const launchJob = selector ? runningJobFor(selector) : null;
  const job = launchJob || (selector ? busyJobFor(selector) : null);
  const info = (job && jobInfo.get(job.id)) || null;

  // Only the banner the CLI prints at exec time means the browser is up. Until
  // then a launch job is a download, and the row has to say so.
  const open = Boolean(launchJob) && Boolean(info) && info.phase === "open";
  const busy = open ? null : job;

  // Docker is the second way to run the same version, with its own image on
  // disk, its own container and its own profile volume - and the row used to
  // know about none of it, so it said "not installed" over a gigabyte of image
  // and showed nothing at all over a browser that was up. The server reports it
  // under the Linux revision a container actually runs, which is never the
  // revision this host installs natively.
  const dk = row.docker || null;
  const dockerRunning = Boolean(dk && dk.state === "running");
  const dockerImage = dk ? dk.imageBytes || 0 : 0;
  const running = open || dockerRunning;

  return {
    raw: row, selector, version, milestone, note, tags, rosetta,
    job, info, busy,
    running: open,             // a native window, which is what Stop acts on
    dockerRunning,
    dockerImage,
    dockerRevision: dk ? String(dk.revision) : null,
    dockerProfileBytes: dk ? dk.profileBytes || 0 : 0,
    dockerStatus: dk ? dk.status || "" : "",
    dockerUrl: dockerRunning && dk.port
      ? `http://localhost:${dk.port}/vnc.html?autoconnect=1&resize=scale` : null,
    // Offered when this milestone has a Linux build to put in a container. The
    // daemon does not have to be up: the launcher offers to start it, the same
    // way the command line does.
    dockerAvailable: Boolean(dk) && Boolean(state.docker && state.docker.cli),
    name: milestone ? `Chromium ${milestone}` : version,
    installed: Boolean(row.installed),
    // "Is this version taking up disk", which an image answers as much as a
    // downloaded build does. The installed filter and count read this.
    onDisk: Boolean(row.installed) || dockerImage > 0,
    supported: row.supported !== false,
    sizeBytes: row.sizeBytes || 0,
    profileBytes: row.profileBytes || 0,
    diskBytes: (row.sizeBytes || 0) + (row.profileBytes || 0) + dockerImage,
    era: row.extra ? null : eraFor(row),
    status: running ? "running"
      : busy ? (info && info.phase === "downloading" ? "downloading" : "working")
      : row.installed || dockerImage ? "installed" : "absent",
    search: [milestone, version, selector ? `r${selector}` : "", raw].join(" ").toLowerCase(),
  };
}

/* ---------- dropdowns ---------- */

function buildDropdown(rootId, buttonId, menuId, labelId, options, get, set) {
  const root = $(rootId);
  const menu = $(menuId);

  const close = () => { menu.hidden = true; root.classList.remove("is-open"); };

  const paint = () => {
    const current = options.find((option) => option.value === get()) || options[0];
    $(labelId).textContent = current.label;
    menu.textContent = "";
    for (const option of options) {
      const item = document.createElement("button");
      item.type = "button";
      if (option.value === get()) item.className = "is-on";
      const tick = iconSpan("check");
      tick.className = "tick";
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
      root.classList.add("is-open");
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

const popoverOpen = () => Boolean(openMenu) || dropdowns.some((handle) => handle.isOpen());

document.addEventListener("click", closePopovers);
document.addEventListener("keydown", (event) => { if (event.key === "Escape") closePopovers(); });

/* ---------- system check ---------- */

let doctorPinned = false;     // shown because the user asked, not because of a fault
let doctorDismissed = false;  // hidden because the user asked, faults and all

const STATUS_WORD = { ok: "ok", missing: "missing", inactive: "not running", na: "not needed" };

const doctorProblems = () => {
  const report = state && state.doctor;
  if (!report || !report.components) return [];
  // "na" means this machine does not need it, so it is not something to act on.
  return report.components.filter((c) => c.status === "missing" || c.status === "inactive");
};

// Only what ChromiumStack cannot work without. The recommended and optional ones
// are worth knowing about, but not worth a panel in front of the shelf on every
// launch - the header button carries the count for those.
const doctorBlockers = () => doctorProblems().filter((c) => c.need === "required");

const doctorVisible = () => doctorPinned || (doctorBlockers().length > 0 && !doctorDismissed);

function renderDoctor() {
  const panel = $("doctor");
  const report = state && state.doctor;
  const problems = doctorProblems();

  const blockers = doctorBlockers();
  const button = $("check-btn");
  button.classList.toggle("has-problem", problems.length > 0 && blockers.length === 0);
  button.classList.toggle("has-blocker", blockers.length > 0);
  button.classList.toggle("is-on", doctorVisible());
  button.querySelector("[data-icon]").innerHTML = icon(problems.length ? "warn" : "ok");
  $("check-label").textContent = problems.length
    ? `${problems.length} check${problems.length > 1 ? "s" : ""}`
    : "System check";

  if (!report || !report.components.length || !doctorVisible()) {
    panel.hidden = true;
    return;
  }

  panel.hidden = false;
  panel.textContent = "";

  const head = document.createElement("div");
  head.className = "doctor-head";
  const heading = document.createElement("h2");
  heading.textContent = "System check";
  const note = document.createElement("span");
  note.className = "muted";
  note.textContent = blockers.length
    ? `${blockers.length} thing${blockers.length > 1 ? "s" : ""} ChromiumStack cannot work without.`
    : problems.length
      ? `Everything required is present. ${problems.length} optional thing${problems.length > 1 ? "s" : ""} you could still sort out.`
      : "Everything ChromiumStack needs is present.";
  const hide = document.createElement("button");
  hide.className = "btn";
  hide.textContent = "Hide";
  hide.onclick = () => {
    doctorPinned = false;
    doctorDismissed = true;
    renderDoctor();
  };
  head.append(heading, note, hide);
  panel.append(head);

  const body = document.createElement("div");
  body.style.display = "flex";
  body.style.flexDirection = "column";
  body.style.gap = "6px";

  // When nothing is wrong the pinned panel lists everything, so the user can see
  // what was actually checked rather than an unexplained "all good".
  const rows = problems.length && !doctorPinned ? problems : report.components;
  for (const component of rows) body.append(doctorRow(component));
  panel.append(body);
}

function doctorRow(component) {
  const row = document.createElement("div");
  row.className = "doctor-row";
  const kind = component.status === "ok" || component.status === "na" ? "ok" : "warn";
  const mark = iconSpan(kind === "ok" ? "ok" : "warn");
  mark.style.color = kind === "ok" ? "var(--c-ok)" : "var(--c-warn)";

  const name = document.createElement("span");
  name.className = "name";
  name.textContent = component.label;

  const pill = document.createElement("span");
  pill.className = `pill ${component.status}`;
  pill.textContent = STATUS_WORD[component.status] || component.status;

  const why = document.createElement("span");
  why.className = "why";
  why.textContent = component.why;

  row.append(mark, name, pill, why);

  const actionable = component.status === "missing" || component.status === "inactive";
  if (actionable && component.fix) {
    const command = document.createElement("code");
    command.className = "cmd";
    command.textContent = component.fix;
    why.append(command);

    const starting = component.status === "inactive";
    const busy = runningDoctorJob(component.id);
    const button = document.createElement("button");
    button.className = "btn";
    button.title = component.note || component.fix;

    if (busy) {
      // Not a dead end and not a lie: it says what is happening, and clicking it
      // brings the log back up if the panel was closed.
      button.textContent = starting ? "Starting…" : "Installing…";
      button.onclick = () => watch(busy.id, `${component.label} — ${component.fix}`);
      row.classList.add("busy");
    } else {
      button.classList.add("accent");
      button.textContent = starting ? "Start it" : "Install";
      button.onclick = async () => {
        button.disabled = true;
        try {
          const { job } = await post("/api/doctor-install", { component: component.id });
          watch(job, `${component.label} — ${component.fix}`);
        } catch (error) {
          // A refused install used to leave a dead button and no explanation.
          showJobFailure(`${component.label} — ${component.fix}`, error.message);
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
    const hint = document.createElement("span");
    hint.className = "pill";
    hint.textContent = "install manually";
    row.append(hint);
  }
  return row;
}

$("check-btn").onclick = () => {
  const visible = doctorVisible();
  doctorPinned = !visible;
  doctorDismissed = visible;
  renderDoctor();
};

/* ---------- whole-list stand-ins ---------- */

function showState({ glyph = "empty", tone = "", title, detail, actionLabel, onAction }) {
  const block = document.createElement("div");
  block.className = `state-block${tone ? ` ${tone}` : ""}`;
  block.innerHTML = icon(glyph);

  const heading = document.createElement("h2");
  heading.textContent = title;
  const text = document.createElement("p");
  text.textContent = detail;
  block.append(heading, text);

  if (actionLabel && onAction) {
    const button = document.createElement("button");
    button.className = "btn accent";
    button.textContent = actionLabel;
    button.onclick = onAction;
    block.append(button);
  }

  const list = $("list");
  list.setAttribute("aria-busy", "false");
  list.textContent = "";
  list.append(block);
}

/* ---------- rendering ---------- */

function render() {
  const rows = [...state.versions, ...state.extra].map(decorate);

  const counts = {
    all: rows.length,
    // A built Docker image is a copy of that version taking up disk, so it
    // counts as installed here even with nothing in the builds directory.
    installed: rows.filter((row) => row.onDisk).length,
    running: rows.filter((row) => row.status === "running").length,
    rosetta: rows.filter((row) => row.rosetta).length,
  };

  renderChrome(rows, counts);
  renderDoctor();
  renderStatusBar();
  renderLogTabs();

  const query = view.query.trim().toLowerCase();
  const visible = rows.filter((row) => {
    if (view.filter === "installed" && !row.onDisk) return false;
    if (view.filter === "running" && row.status !== "running") return false;
    if (view.filter === "rosetta" && !row.rosetta) return false;
    return !query || row.search.includes(query);
  });

  $("summary").textContent =
    `${visible.length} of ${rows.length} versions · ${counts.installed} installed · ${counts.running} running`;

  const list = $("list");
  list.setAttribute("aria-busy", "false");
  list.textContent = "";

  if (!rows.length) {
    showState({
      glyph: "warn",
      title: "No versions in the catalog",
      detail: "catalog.tsv is missing or empty. Rebuild it from the Chromium " +
              "archive with:  python3 tools/refresh-catalog.py",
    });
    return;
  }

  if (!visible.length) {
    showState({
      glyph: "search",
      title: "Nothing matches that filter",
      detail: view.filter === "installed"
        ? "No browser has been downloaded into this profile directory yet, and no " +
          "Docker image has been built either."
        : "No catalogued version matches the current filter and search.",
      actionLabel: "Reset filters",
      onAction: () => {
        view.filter = "all";
        view.query = "";
        $("query").value = "";
        render();
      },
    });
    return;
  }

  for (const group of groupRows(visible)) list.append(renderGroup(group));
  lastPaint = paintSignature();
}

// Header, sidebar and the disk read-outs: everything outside the shelf itself.
function renderChrome(rows, counts) {
  $("host").textContent = `${state.os}/${state.arch} · ${state.hostPlatforms[0] || "?"}`;
  $("foot-path").textContent = `Files in ${state.root}`;

  const browsers = rows.reduce((total, row) => total + row.sizeBytes, 0);
  const profiles = rows.reduce((total, row) => total + row.profileBytes, 0);
  // Images and their profile volumes live inside Docker rather than under the
  // ChromiumStack directory, so nothing that walks the file tree can see them -
  // and at a gigabyte each they were the largest thing this gauge left out.
  const containers = state.dockerBytes || 0;
  const total = browsers + profiles + containers;
  const share = (value) => `${total ? (value / total) * 100 : 0}%`;

  $("disk-text").textContent = mb(total);
  $("gauge").title = containers
    ? `${mb(browsers)} of browsers, ${mb(profiles)} of profiles and ${mb(containers)} of Docker images`
    : `${mb(browsers)} of browsers and ${mb(profiles)} of profiles on disk`;
  for (const [id, value] of [["browsers", browsers], ["profiles", profiles], ["docker", containers]]) {
    $(`disk-seg-${id}`).style.width = share(value);
    $(`card-seg-${id}`).style.width = share(value);
  }
  $("disk-browsers").textContent = mb(browsers);
  $("disk-profiles").textContent = mb(profiles);
  $("disk-docker").textContent = mb(containers);
  // Hidden rather than shown as zero: most machines never build an image, and a
  // permanent "Docker 0 MB" line would be noise on all of them.
  $("disk-docker-line").hidden = containers === 0;

  for (const button of document.querySelectorAll("[data-filter]")) {
    button.classList.toggle("is-on", button.dataset.filter === view.filter);
  }
  for (const slot of document.querySelectorAll("[data-count]")) {
    slot.textContent = counts[slot.dataset.count];
  }
  // Rosetta only exists on Apple Silicon; elsewhere the filter would always be empty.
  $("filter-rosetta").hidden = counts.rosetta === 0;

  const eras = $("eras");
  eras.textContent = "";
  for (const era of view.sort === "new" ? [...ERAS].reverse() : ERAS) {
    const count = rows.filter((row) => row.era === era).length;
    if (!count) continue;
    const button = document.createElement("button");
    button.className = "era-btn";
    const label = document.createElement("span");
    label.textContent = era.label;
    const tally = document.createElement("span");
    tally.className = "count mono";
    tally.textContent = count;
    button.append(label, tally);
    button.onclick = () => {
      const section = document.getElementById(era.id);
      if (section) $("main").scrollTo({ top: section.offsetTop - 48, behavior: "smooth" });
    };
    eras.append(button);
  }
  // Sorting by disk collapses the eras into one group, so the jump list would
  // point at sections that are no longer on the page.
  $("eras-group").hidden = !eras.childElementCount || view.sort === "disk";
}

function groupRows(visible) {
  const byMilestone = (a, b) => (Number(b.milestone) || 0) - (Number(a.milestone) || 0);
  const sorted = (rows) => {
    if (view.sort === "old") return rows.slice().sort((a, b) => -byMilestone(a, b));
    if (view.sort === "disk") return rows.slice().sort((a, b) => b.diskBytes - a.diskBytes);
    return rows.slice().sort(byMilestone);
  };

  if (view.sort === "disk") {
    return [{ id: "by-disk", label: "By disk used", blurb: "largest first", rows: sorted(visible) }];
  }

  const groups = ERAS.map((era) => ({
    id: era.id,
    label: era.label,
    blurb: era.blurb,
    rows: sorted(visible.filter((row) => row.era === era)),
  })).filter((group) => group.rows.length);
  // Oldest era first reads as a timeline and matches the jump list; newest-first
  // has to turn both around, which is what this used to get backwards.
  if (view.sort === "new") groups.reverse();

  // Builds installed by raw revision, and anything the catalog cannot date.
  const loose = visible.filter((row) => !row.era);
  if (loose.length) {
    groups.unshift({ id: "loose", label: "Added by revision", blurb: "pinned manually", rows: sorted(loose) });
  }
  return groups;
}

function renderGroup(group) {
  const section = document.createElement("section");
  section.id = group.id;

  const head = document.createElement("div");
  head.className = "group-head";
  const heading = document.createElement("h2");
  heading.textContent = group.label;
  const blurb = document.createElement("span");
  blurb.className = "blurb";
  blurb.textContent = group.blurb;
  const rule = document.createElement("span");
  rule.className = "rule";
  head.append(heading, blurb, rule);

  const body = document.createElement("div");
  body.className = "group-rows";
  for (const row of group.rows) body.append(renderRow(row));

  section.append(head, body);
  return section;
}

function renderRow(row) {
  const node = $("row-template").content.firstElementChild.cloneNode(true);

  node.querySelector("[data-title]").textContent = row.name;
  node.querySelector("[data-rev]").textContent = row.selector ? `r${row.selector}` : "";
  node.querySelector("[data-note]").textContent = row.note;

  const dot = node.querySelector("[data-dot]");
  dot.dataset.state = row.status;
  dot.title = row.running ? "Running"
    : row.dockerRunning ? `Running in Docker — ${row.dockerStatus || "container up"}`
    : row.busy ? row.busy.label
    : row.installed ? "Installed"
    : row.dockerImage ? "Docker image built, not running" : "Not installed";

  const tags = node.querySelector("[data-tags]");
  for (const text of row.tags) {
    const tag = document.createElement("span");
    tag.className = "tag";
    tag.textContent = text;
    tags.append(tag);
  }

  const badge = document.createElement("span");
  badge.className = "badge";
  if (!row.supported) {
    badge.textContent = "no build for this host";
  } else if (row.rosetta) {
    // Worth calling out: these are the builds that go through Rosetta, and the
    // ones where the stack-profiler crash shows up.
    badge.textContent = "x86_64 · Rosetta";
    badge.classList.add("rosetta");
    badge.title = "No arm64 build exists this far back, so it runs under Rosetta.";
  } else {
    badge.textContent = PLATFORM_LABELS[row.raw.platformDir] || row.raw.platformDir || "";
  }
  if (badge.textContent) tags.append(badge);

  // Docker gets its own marker rather than a share of the fixed-width size
  // column: it is a separate copy of the browser, and when the container is up
  // this is also the way back to the tab showing its desktop.
  if (row.dockerRunning || row.dockerImage) {
    const mark = document.createElement(row.dockerUrl ? "a" : "span");
    mark.className = "badge docker";
    if (row.dockerRunning) {
      mark.textContent = "Docker · running";
      mark.classList.add("is-live");
      const held = `${mb(row.dockerImage)} image` +
                   (row.dockerProfileBytes ? ` · ${mb(row.dockerProfileBytes)} profile` : "");
      mark.title = row.dockerUrl
        ? `${row.dockerStatus} · ${held} — open the desktop`
        : `${row.dockerStatus || "Container up"} · ${held}`;
      if (row.dockerUrl) {
        mark.href = row.dockerUrl;
        mark.target = "_blank";
        mark.rel = "noopener";
      }
    } else {
      mark.textContent = `Docker · ${mb(row.dockerImage)}`;
      mark.title = row.dockerProfileBytes
        ? `Image built for the container, plus ${mb(row.dockerProfileBytes)} of profile. ` +
          "Layers shared with other ChromiumStack images are counted once per image."
        : "Image built for the container, not running.";
    }
    tags.append(mark);
  }

  // The version is what identifies a build, so it stays put whatever else the
  // row is doing; sizes and progress words go on their own line under it.
  node.querySelector("[data-version]").textContent = row.supported ? row.version : "";
  node.querySelector("[data-size]").textContent = row.busy
    ? `${workWord(row.busy, row.info)}…`
    : row.installed ? `${mb(row.sizeBytes)} · ${mb(row.profileBytes)} profile`
    // Nothing downloaded natively, but the image is a real copy of this version
    // and the row would otherwise read as empty.
    : row.dockerImage ? `${mb(row.dockerImage)} in Docker`
    : "";

  if (row.busy) {
    // Determinate while curl is reporting, a moving stripe for the steps that
    // cannot be measured - unpacking, deleting, waiting on Docker.
    const bar = node.querySelector("[data-progress]");
    const percent = row.info ? row.info.percent : null;
    bar.hidden = false;
    if (percent == null) bar.classList.add("indeterminate");
    else node.querySelector("[data-progress-bar]").style.width = `${percent}%`;
  }

  if (!row.supported) {
    node.classList.add("unsupported");
  } else {
    if (row.running || row.dockerRunning) node.classList.add("is-running");
    renderActions(node.querySelector("[data-actions]"), row);
  }
  return node;
}

function renderActions(container, row) {
  const selector = row.selector;
  const action = document.createElement("button");
  action.className = "btn";

  if (row.busy) {
    // A download in progress used to leave this saying "Install & launch", which
    // invited a second one while the first was still running.
    const percent = row.info ? row.info.percent : null;
    const word = workWord(row.busy, row.info);
    if (row.status === "downloading" && percent != null) {
      action.append(iconSpan("down-circle"), `${percent}%`);
    } else {
      action.append(iconSpan(row.status === "downloading" ? "down-circle" : "clock"), `${capitalise(word)}…`);
    }
    action.title = "Show what this is doing";
    action.onclick = () => watch(row.busy.id, jobName(row.busy));
  } else if (row.running) {
    // A disabled "Running" button is a dead end; closing the window is the other
    // way out, but the button is right here.
    const jobId = row.job.id;
    if (stopping.has(jobId)) {
      // SIGTERM to the process group takes a moment to bring the window down,
      // and a button still reading "Stop" invited a second press.
      action.append(iconSpan("clock"), "Stopping…");
      action.disabled = true;
      action.title = "Waiting for the browser to close";
    } else {
      action.classList.add("warn");
      action.append(iconSpan("stop"), "Stop");
      action.title = "Close this browser and everything it started";
      action.onclick = async () => {
        stopping.add(jobId);
        render();
        try {
          await post("/api/stop", { job: jobId });
        } catch (error) {
          stopping.delete(jobId);
          showJobFailure(`Stopping ${row.name}`, error.message);
          return;
        }
        setTimeout(refresh, 400);
      };
    }
  } else if (row.dockerRunning) {
    // The container is up, so the version is running even though no native
    // window is - and something is burning CPU that the row has to be able to
    // turn off. The badge next to the version is the way back to the desktop.
    action.classList.add("warn");
    action.append(iconSpan("stop"), "Stop");
    action.title = "Stop the Docker container running this version";
    action.onclick = async () => {
      action.disabled = true;
      try {
        const { job } = await post("/api/docker", { selector: row.dockerRevision, action: "stop" });
        watch(job, `Stopping Docker · ${row.name}`);
      } catch (error) {
        showJobFailure(`Stopping Docker · ${row.name}`, error.message);
        action.disabled = false;
        return;
      }
      refresh();
    };
  } else if (row.installed) {
    action.classList.add("accent");
    action.append(iconSpan("play"), "Launch");
    action.title = "Open this build";
    action.onclick = () => start(action, row);
  } else if (row.dockerImage) {
    // The image is already built, so this is one click and no download - the
    // same shape as Launch, which is what it is.
    action.classList.add("accent");
    action.append(iconSpan("cube"), "Launch");
    action.title = "Run this version in its Docker container and open the desktop";
    action.onclick = () => startDocker(action, row);
  } else {
    action.append(iconSpan("download"), "Get");
    action.title = "Download this build and launch it";
    action.onclick = () => start(action, row);
  }
  container.append(action);

  const more = document.createElement("button");
  more.className = "btn icon-btn";
  more.append(iconSpan("dots"));
  more.title = "More actions";
  more.onclick = (event) => {
    event.stopPropagation();
    toggleMenu(container, row);
  };
  container.append(more);
}

async function start(button, row) {
  button.disabled = true;
  try {
    const { job } = await post("/api/launch", { selector: row.selector, ...launchOptions() });
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
  button.disabled = true;
  try {
    const { job } = await post("/api/docker", { selector: row.dockerRevision, action: "start" });
    watch(job, `Docker · ${row.name}`);
  } catch (error) {
    showJobFailure(`Docker · ${row.name}`, error.message);
    button.disabled = false;
    return;
  }
  refresh();
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
  const menu = document.createElement("div");
  menu.className = "menu";

  const item = (glyph, label, handler, danger = false) => {
    const button = document.createElement("button");
    button.type = "button";
    button.append(iconSpan(glyph), label);
    if (danger) button.className = "danger";
    button.onclick = async () => {
      closePopovers();
      await handler();
      refresh();
    };
    menu.append(button);
  };

  if (!row.installed) {
    item("download", "Download only", async () => {
      const { job } = await post("/api/install", { selector });
      watch(job, `Installing ${row.name}`);
    });
  }

  // Docker, if this milestone has a Linux build to put in a container. Every
  // action is keyed by that Linux revision, which is the mismatch that used to
  // leave a running container looking stopped: the shelf compared it against the
  // revision this host installs natively, and the two are never the same.
  const docker = row.dockerRevision;
  if (row.dockerAvailable) {
    if (row.dockerRunning) {
      if (row.dockerUrl) {
        item("link", "Open the desktop", async () => {
          window.open(row.dockerUrl, "_blank", "noopener");
        });
      }
      item("stop", "Stop the container", async () => {
        const { job } = await post("/api/docker", { selector: docker, action: "stop" });
        watch(job, `Stopping Docker · ${row.name}`);
      });
      if (row.installed) {
        // Both ways of running this version are available and only one of them
        // has the row's button, so the other cannot be a dead end.
        item("play", "Launch natively as well", async () => {
          const { job } = await post("/api/launch", { selector, ...launchOptions() });
          watch(job, row.name);
        });
      }
    } else {
      item("cube", row.dockerImage
        ? "Run in Docker (noVNC)"
        : "Run in Docker (builds an image first)", async () => {
        const { job } = await post("/api/docker", { selector: docker, action: "start" });
        watch(job, `Docker · ${row.name}`);
      });
    }
    if (row.dockerImage) {
      const held = row.dockerImage + row.dockerProfileBytes;
      item("trash", `Delete Docker image (${mb(row.dockerImage)})`, async () => {
        const go = await askConfirm({
          title: `Delete the Docker image for ${row.name}?`,
          body: `Frees up to ${mb(held)}, less whatever layers other ChromiumStack images ` +
                "share. The container's profile is kept, so building it again restores " +
                "your session. Building takes several minutes.",
          label: "Delete image",
        });
        if (!go) return;
        const { job } = await post("/api/docker", { selector: docker, action: "purge" });
        watch(job, `Removing Docker image · ${row.name}`);
      }, true);
    }
  }

  if (row.installed) {
    menu.append(document.createElement("hr"));
    item("reset", "Reset profile", async () => {
      const go = await askConfirm({
        title: `Reset the profile for ${row.name}?`,
        body: "Cookies, logins and storage for this version are deleted. The browser itself stays, so the next launch starts clean.",
        label: "Reset profile",
      });
      if (!go) return;
      const { job } = await post("/api/clean", { selector });
      watch(job, `Resetting profile · ${row.name}`);
    }, true);
    item("trash", `Delete browser (${mb(row.sizeBytes)})`, async () => {
      const go = await askConfirm({
        title: `Delete the downloaded ${row.name}?`,
        body: `Frees ${mb(row.sizeBytes)}. The profile is kept, so downloading it again restores your session.`,
        label: "Delete browser",
      });
      if (!go) return;
      const { job } = await post("/api/remove", { selector });
      watch(job, `Removing ${row.name}`);
    }, true);
    item("trash", `Delete browser and profile (${mb(row.sizeBytes + row.profileBytes)})`, async () => {
      const go = await askConfirm({
        title: `Delete ${row.name} and its profile?`,
        body: `Frees ${mb(row.sizeBytes + row.profileBytes)}. Cookies and logins for this version are gone for good.`,
        label: "Delete both",
      });
      if (!go) return;
      const { job } = await post("/api/remove", { selector, withProfile: true });
      watch(job, `Removing ${row.name}`);
    }, true);
  }

  container.append(menu);
  openMenu = menu;

  // The shelf is a scroll container: near its bottom edge a downward menu would
  // be clipped rather than overflowing the page, so it flips above the row.
  const rect = container.getBoundingClientRect();
  if (rect.bottom + menu.offsetHeight + 12 > window.innerHeight) menu.classList.add("up");
}

/* ---------- status bar ---------- */

// One job at a time gets the status bar: whatever the log panel is watching if it
// is still running, otherwise the first piece of background work.
function activeJob() {
  const running = state ? state.jobs : [];
  return running.find((job) => job.id === watching)
    || running.find((job) => job.kind !== "launch")
    || running[0]
    || null;
}

function renderStatusBar() {
  const job = activeJob();
  const bar = $("job-bar");

  // Everything else that is busy, reachable in one click.
  const others = (state ? state.jobs.length : 0) - (job ? 1 : 0);
  const more = $("job-more");
  more.hidden = others < 1;
  more.textContent = others < 1 ? "" : `+${others} more`;
  more.title = others < 1 ? "" : "Show the other running jobs";

  if (!job) {
    // A container is not a job: the launcher exits the moment the desktop
    // answers, so with one running and nothing else happening this bar used to
    // read "Nothing running" underneath an open browser.
    const containers = state ? asArray(state.docker && state.docker.containers).length : 0;
    $("job-dot").dataset.state = containers ? "running" : "idle";
    $("job-title").textContent = !containers ? "Ready"
      : containers === 1 ? "1 version running in Docker"
      : `${containers} versions running in Docker`;
    $("job-detail").textContent = containers ? "nothing else in progress" : "Nothing running";
    bar.hidden = true;
    return;
  }

  const info = jobInfo.get(job.id) || null;
  const open = job.kind === "launch" && info && info.phase === "open";

  $("job-dot").dataset.state = open ? "running" : "working";
  $("job-title").textContent = jobTitle(job, info);

  if (open) {
    $("job-detail").textContent = "running";
    bar.hidden = true;
    return;
  }

  const percent = info ? info.percent : null;
  // The byte counts and time left when curl is reporting them, the step's own
  // name when it has nothing to report.
  $("job-detail").textContent = (info && info.detail) || `${workWord(job, info)}…`;
  bar.hidden = false;
  bar.classList.toggle("indeterminate", percent == null);
  $("job-bar-fill").style.width = percent == null ? "" : `${percent}%`;
}

// /api/state lists the running jobs but not their output, and the output is
// where the phase and the meter are. One read per running job per refresh.
async function sampleJobs() {
  const running = state ? state.jobs.filter((job) => job.kind !== "doctor") : [];
  await Promise.all(running.map(async (job) => {
    if (job.id === watching) return;      // pollJob is already reading this one
    try {
      noteJob(job, (await api(`/api/job/${job.id}`)).output);
    } catch { /* the next refresh will try again */ }
  }));
  for (const id of [...jobInfo.keys()]) {
    if (id !== watching && !running.some((job) => job.id === id)) jobInfo.delete(id);
  }
  for (const id of [...stopping]) {
    if (!state.jobs.some((job) => job.id === id)) stopping.delete(id);
  }
}

// Rows carry a live percentage, so the 700ms poll repaints them - but only when
// something actually moved, and never over an open menu.
let lastPaint = "";

const paintSignature = () => !state ? "" : state.jobs
  .map((job) => { const info = jobInfo.get(job.id) || {}; return `${job.id}:${info.phase}:${info.percent}`; })
  .join("|");

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
  if (before && before.phase !== info.phase && info.phase === "ready") {
    flash(`${jobName(job)} downloaded`);
  }
  return info;
}

/* ---------- job log ----------
   Several versions can be busy at once - two browsers open while a third
   downloads - so the panel is a switcher over the running jobs rather than one
   slot that whichever job started last takes over. */

function setLogOpen(open) {
  $("log-panel").hidden = !open;
  $("log-btn-label").textContent = open ? "Hide log" : "Show log";
}

function renderLogTabs() {
  const tabs = $("log-tabs");
  tabs.textContent = "";

  const list = state ? [...state.jobs] : [];
  // A job that has just finished keeps its tab: its output is usually the reason
  // the panel is open in the first place.
  if (watching && !list.some((job) => job.id === watching)) {
    list.push({ id: watching, kind: "done", revision: null, label: watchedTitle });
  }

  // With one job there is nothing to switch between, so it reads as a title.
  $("log-title").hidden = list.length > 1;
  $("log-title").textContent = list.length > 1 ? "" : watchedTitle;
  tabs.hidden = list.length < 2;
  if (list.length < 2) return;

  for (const job of list) {
    const info = jobInfo.get(job.id) || null;
    const tab = document.createElement("button");
    tab.type = "button";
    tab.className = `log-tab${job.id === watching ? " is-on" : ""}`;

    const dot = document.createElement("span");
    dot.className = "dot";
    dot.dataset.state = job.kind === "done" ? "idle"
      : info && info.phase === "open" ? "running"
      : info && info.phase === "downloading" ? "downloading" : "working";

    const name = document.createElement("span");
    name.className = "name";
    name.textContent = jobName(job);

    tab.append(dot, name);
    tab.title = job.kind === "done" ? `${jobName(job)} — finished` : jobTitle(job, info);
    if (job.id !== watching) tab.onclick = () => watch(job.id, jobName(job));
    tabs.append(tab);
  }
}

function watch(jobId, title) {
  watching = jobId;
  watchedTitle = title;
  pollFailures = 0;
  setLogOpen(true);
  $("log-status").textContent = "running…";
  $("log-out").textContent = "";
  renderLogTabs();
  pollJob();
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
    $("log-status").textContent = "cannot read this job";
    $("log-out").textContent =
      `${error.message}\n\nThe job itself may well be running - this is the manager ` +
      "failing to read its output. The version list still updates, and the launcher " +
      "writes its own log under the ChromiumStack home directory.";
    return;
  }
  if (watching !== jobId) return;
  pollFailures = 0;

  const log = $("log-out");
  const atBottom = log.scrollTop + log.clientHeight >= log.scrollHeight - 20;
  // curl draws its progress bar with carriage returns; keep only the last frame.
  log.textContent = (job.output || "").split("\n").map((line) => line.split("\r").pop()).join("\n");
  if (atBottom) log.scrollTop = log.scrollHeight;

  const info = noteJob(job, job.output);

  const status = $("log-status");
  if (job.status === "running") {
    status.textContent = info.phase === "open"
      ? "running"
      : info.detail ? `${workWord(job, info)} · ${info.detail}` : `${workWord(job, info)}…`;
    renderStatusBar();
    repaintIfMoved();
    setTimeout(pollJob, 700);
  } else {
    status.textContent =
      job.status === "done" ? "finished"
      : job.status === "stopped" ? "stopped"
      : `failed (exit ${job.code})`;
    jobInfo.delete(jobId);
    if (job.status === "done") flash(`${$("log-title").textContent} — finished`);
    refresh();
  }
}

// A request that failed before a job existed still has to be visible somewhere,
// and the log panel is where the user is already looking for output.
function showJobFailure(title, message) {
  watching = null;
  watchedTitle = title;
  setLogOpen(true);
  renderLogTabs();
  $("log-title").textContent = title;
  $("log-status").textContent = "failed";
  $("log-out").textContent = message;
}

$("log-close").onclick = () => {
  watching = null;
  watchedTitle = "";
  setLogOpen(false);
};

$("log-btn").onclick = () => {
  const open = $("log-panel").hidden;
  setLogOpen(open);
  if (!open) return;
  const job = activeJob();
  if (!watching && job) {
    watch(job.id, jobName(job));
  } else if (!watching) {
    watchedTitle = "No job yet";
    renderLogTabs();
    $("log-status").textContent = "output from installs, launches and clean-ups shows up here";
  }
};

/* ---------- toast ---------- */

let toastTimer = null;

function flash(message, tone = "ok") {
  $("toast-text").textContent = message;
  $("toast-icon").innerHTML = icon(tone === "ok" ? "ok" : "warn");
  const toast = $("toast");
  toast.classList.toggle("warn", tone !== "ok");
  toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { toast.hidden = true; }, 2600);
}

/* ---------- confirm ----------
   Deleting a browser and resetting a profile are the two things here that cannot
   be undone, and window.confirm put a browser-chrome dialog in front of them
   that says which host is asking rather than what is about to happen. */

function askConfirm({ title, body, label }) {
  const dialog = $("confirm-dialog");
  $("confirm-title").textContent = title;
  $("confirm-body").textContent = body;
  $("confirm-ok").textContent = label;
  dialog.returnValue = "";
  return new Promise((resolve) => {
    dialog.addEventListener("close", function once() {
      dialog.removeEventListener("close", once);
      resolve(dialog.returnValue === "ok");   // Escape closes with neither value
    });
    dialog.showModal();
  });
}

/* ---------- add by revision ---------- */

$("add-btn").onclick = () => $("add-dialog").showModal();

$("add-dialog").addEventListener("close", async (event) => {
  const dialog = event.target;
  const revision = $("add-revision").value.trim();
  $("add-revision").value = "";
  if (dialog.returnValue !== "ok") return;
  if (!/^\d{4,}$/.test(revision)) {
    flash("A revision is a number from the snapshot archive, e.g. 638880.", "warn");
    return;
  }
  const { job } = await post("/api/install", { selector: revision });
  watch(job, `Installing r${revision}`);
});

$("add-revision").addEventListener("input", (event) => {
  event.target.value = event.target.value.replace(/\D/g, "");
});

/* ---------- controls ---------- */

$("job-more").onclick = () => {
  setLogOpen(true);
  if (!watching) {
    const job = activeJob();
    if (job) watch(job.id, jobName(job));
  }
  renderLogTabs();
};

$("theme-btn").onclick = () => {
  const root = document.documentElement;
  const dark = root.dataset.theme
    ? root.dataset.theme === "dark"
    : matchMedia("(prefers-color-scheme: dark)").matches;
  root.dataset.theme = dark ? "light" : "dark";
  writeStored(THEME_KEY, root.dataset.theme);
};

$("url").addEventListener("input", () => { $("url-clear").hidden = !$("url").value; });
$("url-clear").onclick = () => {
  $("url").value = "";
  $("url-clear").hidden = true;
  $("url").focus();
};

$("query").addEventListener("input", (event) => {
  view.query = event.target.value;
  $("query-clear").hidden = !view.query;
  if (state) render();
});
$("query-clear").onclick = () => {
  view.query = "";
  $("query").value = "";
  $("query-clear").hidden = true;
  if (state) render();
};

for (const button of document.querySelectorAll("[data-filter]")) {
  button.onclick = () => {
    view.filter = button.dataset.filter;
    if (state) render();
  };
}

/* ---------- refresh loop ---------- */

async function refresh() {
  let next;
  try {
    next = await api("/api/state");
  } catch (error) {
    showState({
      glyph: "warn",
      tone: "error",
      title: "Cannot reach the manager",
      detail: `${error.message}. The local server is not answering — it was probably ` +
              "stopped. Reopen ChromiumStack, or run ./gui.sh from the project folder.",
      actionLabel: "Try again",
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
  for (const row of next.extra) { row.installed = true; row.extra = true; }
  state = next;
  await sampleJobs();

  try {
    render();
  } catch (error) {
    // Drawing the page failing is not the server being down. Saying it was sent
    // the last one of these looking for a stopped server that was running fine.
    showState({
      glyph: "warn",
      tone: "error",
      title: "Could not draw the version list",
      detail: `${error.message}. The manager itself is still running, so this is a bug ` +
              "in the page rather than a problem with your machine.",
      actionLabel: "Reload",
      onAction: () => location.reload(),
    });
  }

}

(async function boot() {
  paintIcons();
  buildDropdown("gpu-drop", "gpu-btn", "gpu-menu", "gpu-label", [
    { value: "auto", label: "GPU auto" },
    { value: "on", label: "Force GPU on" },
    { value: "off", label: "Force GPU off" },
  ], () => view.gpu, (value) => { view.gpu = value; });

  buildDropdown("sort-drop", "sort-btn", "sort-menu", "sort-label", [
    { value: "new", label: "Newest first" },
    { value: "old", label: "Oldest first" },
    { value: "disk", label: "Disk used" },
  ], () => view.sort, (value) => { view.sort = value; if (state) render(); });

  TOKEN = (await (await fetch("/api/token")).json()).token;
  await refresh();
  setInterval(() => {
    // Keep the running dots honest without fighting an open menu or a dialog.
    if (!popoverOpen() && !document.querySelector("dialog[open]")) refresh();
  }, 4000);
})();
