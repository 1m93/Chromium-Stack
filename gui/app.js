/* chromium-stack manager — talks to gui/server.py (or gui/server.ps1 on Windows). */

const $ = (id) => document.getElementById(id);

const PLATFORM_LABELS = {
  Mac_Arm: "native arm64",
  Mac: "x86_64",
  Linux_x64: "Linux x86_64",
  Win_x64: "Windows x86_64",
};

let TOKEN = null;
let state = null;
let openMenu = null;
let watching = null;      // job id currently shown in the drawer
let pollFailures = 0;     // consecutive failed polls of the watched job

// The server is the source of truth for what is running, so this survives a reload.
const runningJobFor = (selector) =>
  state.jobs.find((job) => job.kind === "launch" && String(job.revision) === selector);

// Anything else the server is doing to a version: a download, a delete, a profile
// reset, a Docker container coming up. Launches are excluded because a running
// browser gets a Stop button rather than a label.
const busyJobFor = (selector) =>
  state.jobs.find((job) => job.kind !== "launch" && job.kind !== "doctor" &&
                           String(job.revision) === selector);

const JOB_VERB = { install: "Installing…", remove: "Removing…", clean: "Resetting…", docker: "Docker…" };

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
  const gpu = $("gpu").value;
  return {
    url: $("url").value.trim(),
    size: $("size").value.trim(),
    gpu: gpu === "auto" ? null : gpu === "on",
  };
}

/* ---------- system check ---------- */

let doctorPinned = false;   // shown because the user asked, not because of a fault

const STATUS_WORD = { ok: "ok", missing: "missing", inactive: "not running", na: "not needed" };

function renderDoctor() {
  const panel = $("doctor");
  const report = state && state.doctor;
  if (!report || !report.components.length) {
    panel.hidden = true;
    return;
  }

  // Anything a user can act on. "na" means this machine does not need it.
  const problems = report.components.filter((c) => c.status === "missing" || c.status === "inactive");
  if (!problems.length && !doctorPinned) {
    panel.hidden = true;
    return;
  }

  panel.hidden = false;
  panel.classList.toggle("has-problem", problems.length > 0);
  panel.textContent = "";

  const head = document.createElement("div");
  head.className = "doctor-head";
  const heading = document.createElement("h2");
  heading.textContent = "System check";
  const note = document.createElement("span");
  note.className = "muted";
  note.textContent = problems.length
    ? `${problems.length} thing${problems.length > 1 ? "s" : ""} to sort out — ChromiumStack still works without the optional ones.`
    : "Everything ChromiumStack needs is present.";
  const close = document.createElement("button");
  close.className = "btn ghost small";
  close.textContent = "Hide";
  close.onclick = () => {
    doctorPinned = false;
    renderDoctor();
  };
  head.append(heading, note, close);
  panel.append(head);

  // When nothing is wrong the pinned panel lists everything, so the user can see
  // what was actually checked rather than an unexplained "all good".
  const rows = problems.length && !doctorPinned ? problems : report.components;
  for (const component of rows) panel.append(doctorRow(component));
}

function doctorRow(component) {
  const row = document.createElement("div");
  row.className = "doctor-row";

  const name = document.createElement("span");
  name.className = "name";
  name.textContent = component.label;

  const pill = document.createElement("span");
  pill.className = `pill ${component.status}`;
  pill.textContent = STATUS_WORD[component.status] || component.status;

  const why = document.createElement("span");
  why.className = "why";
  why.textContent = component.why;

  row.append(name, pill, why);

  const actionable = component.status === "missing" || component.status === "inactive";
  if (actionable && component.fix) {
    const command = document.createElement("code");
    command.className = "cmd";
    command.textContent = component.fix;
    why.append(command);

    const starting = component.status === "inactive";
    const busy = runningDoctorJob(component.id);
    const button = document.createElement("button");
    button.title = component.note || component.fix;

    if (busy) {
      // Not a dead end and not a lie: it says what is happening, and clicking it
      // brings the log back up if the drawer was closed.
      button.className = "btn ghost";
      button.textContent = starting ? "Starting…" : "Installing…";
      button.onclick = () => watch(busy.id, `${component.label} — ${component.fix}`);
      row.classList.add("busy");
    } else {
      button.className = "btn";
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

$("doctor-btn").onclick = () => {
  doctorPinned = !doctorPinned;
  renderDoctor();
};

/* ---------- empty / error / loading states ---------- */

const STATE_ICONS = {
  empty: '<rect x="3" y="6" width="18" height="14" rx="3"/><path d="M3 10h18"/>',
  warn:  '<circle cx="12" cy="12" r="9"/><path d="M12 8v5"/><path d="M12 16.5v.01"/>',
  wait:  '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
};

/* The list is a grid at wide viewports, so anything that stands in for the whole
   list has to span every column - otherwise it sits in the first cell and reads
   as misaligned rather than centred. */
function showState({ icon = "empty", tone = "", title, detail, actionLabel, onAction }) {
  const block = document.createElement("div");
  block.className = `state-block${tone ? ` ${tone}` : ""}`;

  block.innerHTML = `
    <svg class="state-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor"
         stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"
         aria-hidden="true">${STATE_ICONS[icon] || STATE_ICONS.empty}</svg>
    <h2></h2>
    <p></p>`;
  block.querySelector("h2").textContent = title;
  block.querySelector("p").textContent = detail;

  if (actionLabel && onAction) {
    const button = document.createElement("button");
    button.className = "btn";
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
  const list = $("list");
  const onlyInstalled = $("only-installed").checked;
  const rows = [...state.versions, ...state.extra];
  const visible = rows.filter((row) => (onlyInstalled ? row.installed : true));

  $("host").textContent = `${state.os}/${state.arch} · ${state.hostPlatforms[0]}`;
  $("disk").textContent = `${mb(state.totalBytes)} on disk`;
  $("foot-note").textContent =
    `Files in ${state.root}. Each version keeps its own profile, so a newer build never upgrades an older one's data.`;

  renderDoctor();

  list.setAttribute("aria-busy", "false");
  list.textContent = "";

  if (!visible.length) {
    if (onlyInstalled) {
      showState({
        icon: "empty",
        title: "Nothing installed yet",
        detail: "No browser has been downloaded into this profile directory. " +
                "Show every catalogued version to pick one.",
        actionLabel: "Show all versions",
        onAction: () => {
          $("only-installed").checked = false;
          render();
        },
      });
    } else {
      showState({
        icon: "warn",
        title: "No versions in the catalog",
        detail: "catalog.tsv is missing or empty. Rebuild it from the Chromium " +
                "archive with:  python3 tools/refresh-catalog.py",
      });
    }
    return;
  }

  for (const row of visible) list.append(renderRow(row));
}

function renderRow(row) {
  const node = $("row-template").content.firstElementChild.cloneNode(true);
  const title = row.version || `r${row.revision}`;
  const running = Boolean(row.revision && runningJobFor(String(row.revision)));
  const busy = row.revision && !running ? busyJobFor(String(row.revision)) : null;

  node.querySelector("[data-title]").textContent =
    row.milestone && row.milestone !== "?" ? `Chromium ${row.milestone}` : title;
  node.querySelector("[data-rev]").textContent = row.revision ? `${title} · r${row.revision}` : "";
  node.querySelector("[data-note]").textContent = row.note || "";

  const stateDot = node.querySelector("[data-state]");
  stateDot.dataset.state = running || busy ? "running" : row.installed ? "installed" : "absent";
  stateDot.title = running ? "Running"
    : busy ? busy.label
    : row.installed ? "Installed" : "Not installed";

  const badge = node.querySelector("[data-platform]");
  if (!row.supported) {
    badge.textContent = "no build for this host";
  } else if (row.platformDir === "Mac" && state.arch === "arm64") {
    // Worth calling out: these are the builds that go through Rosetta, and the
    // ones where the stack-profiler crash shows up.
    badge.textContent = "x86_64 · Rosetta";
    badge.classList.add("rosetta");
    badge.title = "No arm64 build exists this far back, so it runs under Rosetta.";
  } else {
    badge.textContent = PLATFORM_LABELS[row.platformDir] || row.platformDir || "";
  }

  node.querySelector("[data-meta]").textContent = row.installed
    ? `${mb(row.sizeBytes)} browser · ${mb(row.profileBytes)} profile`
    : row.supported
      ? "not installed"
      : "";

  if (!row.supported) node.classList.add("unsupported");
  else renderActions(node.querySelector("[data-actions]"), row, running, busy);

  return node;
}

function renderActions(container, row, running, busy) {
  const selector = String(row.revision);

  const launch = document.createElement("button");
  if (busy) {
    // A download in progress used to leave this saying "Install & launch", which
    // invited a second one while the first was still running.
    launch.className = "btn ghost";
    launch.textContent = JOB_VERB[busy.kind] || "Working…";
    launch.title = "Show what this is doing";
    launch.onclick = () => watch(busy.id, busy.label);
  } else if (running) {
    // A disabled "Running" button is a dead end; closing the window is the other
    // way out, but the button is right here.
    launch.className = "btn stop";
    launch.textContent = "Stop";
    launch.title = "Close this browser and everything it started";
    launch.onclick = async () => {
      launch.disabled = true;
      await post("/api/stop", { job: runningJobFor(selector).id });
      setTimeout(refresh, 400);
    };
  } else {
    launch.className = "btn primary";
    launch.textContent = row.installed ? "Launch" : "Install & launch";
    launch.onclick = async () => {
      launch.disabled = true;
      const { job } = await post("/api/launch", { selector, ...launchOptions() });
      watch(job, `Chromium ${row.milestone ?? selector}`);
      refresh();
    };
  }
  container.append(launch);

  const more = document.createElement("button");
  more.className = "btn icon";
  more.textContent = "···";
  more.title = "More actions";
  more.onclick = (event) => {
    event.stopPropagation();
    toggleMenu(container, row);
  };
  container.append(more);
}

function toggleMenu(container, row) {
  if (openMenu) {
    const wasSame = openMenu.parentElement === container;
    openMenu.remove();
    openMenu = null;
    if (wasSame) return;
  }

  const selector = String(row.revision);
  const menu = document.createElement("div");
  menu.className = "menu";

  const item = (label, handler, danger = false) => {
    const button = document.createElement("button");
    button.textContent = label;
    if (danger) button.className = "danger";
    button.onclick = async () => {
      menu.remove();
      openMenu = null;
      await handler();
      refresh();
    };
    menu.append(button);
  };

  if (!row.installed) {
    item("Download only", async () => {
      const { job } = await post("/api/install", { selector });
      watch(job, `Installing Chromium ${row.milestone ?? selector}`);
    });
  }

  if (state.docker.supported) {
    item("Run in Docker (noVNC)", async () => {
      const { job } = await post("/api/docker", { selector, action: "start" });
      watch(job, `Docker · Chromium ${row.milestone ?? selector}`);
    });
    item("Stop Docker container", async () => {
      const { job } = await post("/api/docker", { selector, action: "stop" });
      watch(job, `Stopping Docker · ${row.milestone ?? selector}`);
    });
  }

  if (row.installed) {
    menu.append(document.createElement("hr"));
    item("Reset profile", async () => {
      if (!confirm(`Reset the profile for Chromium ${row.milestone ?? selector}?\n\nCookies, logins and storage for this version are deleted. The browser itself stays.`)) return;
      const { job } = await post("/api/clean", { selector });
      watch(job, `Resetting profile`);
    }, true);
    item(`Delete browser (${mb(row.sizeBytes)})`, async () => {
      if (!confirm(`Delete the downloaded Chromium ${row.milestone ?? selector}?\n\nFrees ${mb(row.sizeBytes)}. The profile is kept, so reinstalling restores your session.`)) return;
      const { job } = await post("/api/remove", { selector });
      watch(job, `Removing Chromium ${row.milestone ?? selector}`);
    }, true);
    item(`Delete browser and profile (${mb(row.sizeBytes + row.profileBytes)})`, async () => {
      if (!confirm(`Delete Chromium ${row.milestone ?? selector} and its profile?\n\nFrees ${mb(row.sizeBytes + row.profileBytes)}. Cookies and logins for this version are gone for good.`)) return;
      const { job } = await post("/api/remove", { selector, withProfile: true });
      watch(job, `Removing Chromium ${row.milestone ?? selector}`);
    }, true);
  }

  container.append(menu);
  openMenu = menu;
}

document.addEventListener("click", () => {
  if (openMenu) {
    openMenu.remove();
    openMenu = null;
  }
});

/* ---------- job drawer ---------- */

function syncDrawerSpace() {
  const drawer = $("drawer");
  document.body.style.paddingBottom = drawer.hidden ? "" : `${drawer.offsetHeight + 24}px`;
}

new ResizeObserver(syncDrawerSpace).observe($("drawer"));

function watch(jobId, title) {
  watching = jobId;
  pollFailures = 0;
  $("drawer").hidden = false;
  $("drawer-title").textContent = title;
  $("drawer-status").textContent = "running…";
  $("drawer-log").textContent = "";
  syncDrawerSpace();
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
    $("drawer-status").textContent = "cannot read this job";
    $("drawer-log").textContent =
      `${error.message}\n\nThe job itself may well be running - this is the manager ` +
      "failing to read its output. The version list still updates, and the launcher " +
      "writes its own log under the ChromiumStack home directory.";
    return;
  }
  if (watching !== jobId) return;
  pollFailures = 0;

  const log = $("drawer-log");
  const atBottom = log.scrollTop + log.clientHeight >= log.scrollHeight - 20;
  // curl draws its progress bar with carriage returns; keep only the last frame.
  log.textContent = (job.output || "").split("\n").map((line) => line.split("\r").pop()).join("\n");
  if (atBottom) log.scrollTop = log.scrollHeight;

  const status = $("drawer-status");
  if (job.status === "running") {
    status.textContent = job.kind === "launch" ? "browser open — close it to finish" : "running…";
    setTimeout(pollJob, 700);
  } else {
    status.textContent =
      job.status === "done" ? "finished"
      : job.status === "stopped" ? "stopped"
      : `failed (exit ${job.code})`;
    refresh();
  }
}

// A request that failed before a job existed still has to be visible somewhere,
// and the drawer is where the user is already looking for output.
function showJobFailure(title, message) {
  watching = null;
  $("drawer").hidden = false;
  $("drawer-title").textContent = title;
  $("drawer-status").textContent = "failed";
  $("drawer-log").textContent = message;
  syncDrawerSpace();
}

$("drawer-close").onclick = () => {
  watching = null;
  $("drawer").hidden = true;
  syncDrawerSpace();
};

/* ---------- add by revision ---------- */

$("add-btn").onclick = () => $("add-dialog").showModal();

$("add-dialog").addEventListener("close", async (event) => {
  const dialog = event.target;
  if (dialog.returnValue !== "ok") return;
  const revision = $("add-revision").value.trim();
  if (!/^\d{4,}$/.test(revision)) {
    alert("A revision is a number from the snapshot archive, e.g. 638880.");
    return;
  }
  const { job } = await post("/api/install", { selector: revision });
  watch(job, `Installing r${revision}`);
});

/* ---------- refresh loop ---------- */

async function refresh() {
  let next;
  try {
    next = await api("/api/state");
  } catch (error) {
    showState({
      icon: "warn",
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
  state = next;

  try {
    render();
  } catch (error) {
    // Drawing the page failing is not the server being down. Saying it was sent
    // the last one of these looking for a stopped server that was running fine.
    showState({
      icon: "warn",
      tone: "error",
      title: "Could not draw the version list",
      detail: `${error.message}. The manager itself is still running, so this is a bug ` +
              "in the page rather than a problem with your machine.",
      actionLabel: "Reload",
      onAction: () => location.reload(),
    });
  }
}

$("only-installed").onchange = render;

(async function start() {
  TOKEN = (await (await fetch("/api/token")).json()).token;
  await refresh();
  setInterval(() => {
    // Keep the running dots honest without fighting an open menu or a dialog.
    if (!openMenu && !document.querySelector("dialog[open]")) refresh();
  }, 4000);
})();
