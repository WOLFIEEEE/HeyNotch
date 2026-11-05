"use strict";

(() => {
  document.documentElement.classList.add("js");
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const tabs = [...document.querySelectorAll("[data-tab]")];
  const panels = [...document.querySelectorAll(".demo-panel")];
  const status = document.getElementById("demo-status");
  const board = document.getElementById("demo-board");
  const laptop = document.getElementById("laptop");
  const stage = document.getElementById("scene-stage");
  const musicToggle = document.getElementById("music-toggle");
  const meetingToggle = document.getElementById("meeting-toggle");
  const agentRun = document.getElementById("agent-run");
  const agentResult = document.getElementById("agent-result");
  const initialTasks = [
    { id: "idea", title: "Sketch the next idea", column: "todo" },
    { id: "draft", title: "Send the draft", column: "todo" },
    { id: "life", title: "Bring it to life", column: "doing" },
    { id: "start", title: "Find a good starting point", column: "done" }
  ];
  const columns = ["todo", "doing", "done"];
  const columnNames = { todo: "To do", doing: "Doing", done: "Done" };
  let tasks = initialTasks.map(task => ({ ...task }));
  let activeTab = "tasks";
  let playing = false;
  let transcriptShown = false;

  const announce = message => { status.textContent = message; };

  function renderTasks(focusID) {
    for (const column of columns) {
      const lane = board.querySelector(`[data-column="${column}"] .lane-tasks`);
      const items = tasks.filter(task => task.column === column);
      board.querySelector(`[data-count="${column}"]`).textContent = items.length;
      lane.replaceChildren();
      for (const task of items) {
        const row = document.createElement("div");
        row.setAttribute("role", "listitem");
        const button = document.createElement("button");
        button.className = "demo-task";
        button.dataset.taskId = task.id;
        const next = columns[(columns.indexOf(column) + 1) % columns.length];
        button.setAttribute("aria-label", `${task.title}, ${columnNames[column]}. Move to ${columnNames[next]} in the browser preview.`);
        const title = document.createElement("strong");
        title.textContent = task.title;
        const detail = document.createElement("span");
        detail.textContent = column === "doing" ? "On this Mac" : column === "done" ? "Completed" : "Work";
        button.append(title, detail);
        row.append(button);
        lane.append(row);
      }
      if (!items.length) {
        const empty = document.createElement("div");
        empty.className = "empty-lane";
        empty.setAttribute("role", "listitem");
        empty.textContent = column === "done" ? "A little room for progress." : "A little breathing room.";
        lane.append(empty);
      }
    }
    if (focusID) {
      [...board.querySelectorAll("[data-task-id]")].find(button => button.dataset.taskId === focusID)?.focus({ preventScroll: true });
    }
  }

  function setPlaying(value, shouldAnnounce = true) {
    playing = value;
    laptop.classList.toggle("is-playing", playing);
    musicToggle.setAttribute("aria-pressed", String(playing));
    musicToggle.setAttribute("aria-label", playing ? "Pause the silent music preview" : "Play the silent music preview");
    musicToggle.querySelector("use").setAttribute("href", playing ? "#i-pause" : "#i-play");
    if (shouldAnnounce) announce(playing ? "Silent music preview playing. No audio is produced." : "Silent music preview paused.");
  }

  function selectTab(name, focus = false, shouldAnnounce = true) {
    if (!tabs.some(tab => tab.dataset.tab === name)) return;
    activeTab = name;
    tabs.forEach(tab => {
      const selected = tab.dataset.tab === name;
      tab.setAttribute("aria-selected", String(selected));
      tab.tabIndex = selected ? 0 : -1;
      if (selected && focus) tab.focus({ preventScroll: true });
    });
    panels.forEach(panel => { panel.hidden = panel.id !== `panel-${name}`; });
    if (name !== "music") setPlaying(false, false);
    const messages = {
      tasks: "Click a sample task to move it to the next column. Changes stay in this page.",
      music: "A silent preview of your music controls. No audio or music app connection.",
      meetings: "Explore a sample transcript. This page never accesses your microphone or camera.",
      agent: "Try a preset request. It creates a sample task in this browser preview only."
    };
    if (shouldAnnounce) announce(messages[name]);
  }

  tabs.forEach((tab, index) => {
    tab.disabled = false;
    tab.addEventListener("click", () => selectTab(tab.dataset.tab));
    tab.addEventListener("keydown", event => {
      let next;
      if (event.key === "ArrowRight") next = (index + 1) % tabs.length;
      else if (event.key === "ArrowLeft") next = (index - 1 + tabs.length) % tabs.length;
      else if (event.key === "Home") next = 0;
      else if (event.key === "End") next = tabs.length - 1;
      else return;
      event.preventDefault();
      selectTab(tabs[next].dataset.tab, true);
    });
  });
  board.addEventListener("click", event => {
    const button = event.target.closest("button[data-task-id]");
    if (!button || !board.contains(button)) return;
    const task = tasks.find(item => item.id === button.dataset.taskId);
    if (!task) return;
    task.column = columns[(columns.indexOf(task.column) + 1) % columns.length];
    renderTasks(task.id);
    announce(`“${task.title}” moved to ${columnNames[task.column]}. Browser preview only; Reminders is unchanged.`);
  });
  musicToggle.disabled = false;
  musicToggle.addEventListener("click", () => setPlaying(!playing));
  meetingToggle.disabled = false;
  meetingToggle.addEventListener("click", () => {
    transcriptShown = !transcriptShown;
    meetingToggle.setAttribute("aria-expanded", String(transcriptShown));
    document.getElementById("sample-lines").hidden = !transcriptShown;
    document.getElementById("meeting-placeholder").hidden = transcriptShown;
    meetingToggle.firstChild.textContent = transcriptShown ? "Hide sample transcript " : "Show sample transcript ";
    announce(transcriptShown ? "Sample transcript shown, with separate microphone and call-audio passages. No recording has taken place." : "Sample transcript hidden. No recording has taken place.");
  });
  agentRun.disabled = false;
  agentRun.addEventListener("click", () => {
    if (tasks.some(task => task.id === "agent-proposal")) {
      selectTab("tasks", true);
      announce("The sample task “Review the proposal” is in this preview’s Work list.");
      return;
    }
    tasks.push({ id: "agent-proposal", title: "Review the proposal", column: "todo" });
    renderTasks();
    agentResult.textContent = "Added to this preview’s Work list.";
    agentRun.firstChild.textContent = "View sample task ";
    announce("Sample task “Review the proposal” created in To do. This is a browser demonstration; no agent or Reminders connection was used.");
  });
  const reset = document.getElementById("reset-demo");
  reset.disabled = false;
  reset.addEventListener("click", () => {
    tasks = initialTasks.map(task => ({ ...task }));
    renderTasks();
    setPlaying(false, false);
    transcriptShown = false;
    document.getElementById("sample-lines").hidden = true;
    document.getElementById("meeting-placeholder").hidden = false;
    meetingToggle.setAttribute("aria-expanded", "false");
    meetingToggle.firstChild.textContent = "Show sample transcript ";
    agentRun.firstChild.textContent = "Try this command ";
    agentResult.textContent = "Creates a browser sample only.";
    selectTab("tasks", false, false);
    announce("Preview reset. All content is sample data and changes stay in this page.");
  });
  document.querySelectorAll("[data-show-tab]").forEach(link => {
    link.addEventListener("click", () => selectTab(link.dataset.showTab));
  });
  renderTasks();

  const navigation = document.getElementById("site-navigation");
  const navigationToggle = document.querySelector(".nav-toggle");
  function closeNavigation() {
    navigation.classList.remove("is-open");
    navigationToggle.setAttribute("aria-expanded", "false");
    navigationToggle.setAttribute("aria-label", "Open navigation");
  }
  navigationToggle.addEventListener("click", () => {
    const open = navigationToggle.getAttribute("aria-expanded") !== "true";
    navigation.classList.toggle("is-open", open);
    navigationToggle.setAttribute("aria-expanded", String(open));
    navigationToggle.setAttribute("aria-label", open ? "Close navigation" : "Open navigation");
  });
  navigation.querySelectorAll("a").forEach(link => link.addEventListener("click", closeNavigation));
  document.addEventListener("pointerdown", event => {
    if (!navigation.contains(event.target) && !navigationToggle.contains(event.target)) closeNavigation();
  });
  document.addEventListener("keydown", event => {
    if (event.key === "Escape" && navigationToggle.getAttribute("aria-expanded") === "true") {
      closeNavigation();
      navigationToggle.focus();
    }
  });

  const dialog = document.getElementById("get-dialog");
  let dialogOpener = null;
  if (typeof dialog.showModal === "function") {
    document.querySelectorAll("[data-get]").forEach(link => {
      link.addEventListener("click", event => {
        event.preventDefault();
        const fromMobileMenu = navigation.contains(link)
          && getComputedStyle(navigationToggle).display !== "none";
        dialogOpener = fromMobileMenu ? navigationToggle : link;
        closeNavigation();
        dialog.showModal();
        document.body.classList.add("dialog-open");
      });
    });
    dialog.querySelector(".dialog-close").addEventListener("click", () => dialog.close());
    dialog.addEventListener("click", event => {
      const box = dialog.getBoundingClientRect();
      if (event.target === dialog && (event.clientX < box.left || event.clientX > box.right || event.clientY < box.top || event.clientY > box.bottom)) dialog.close();
    });
    dialog.addEventListener("close", () => {
      document.body.classList.remove("dialog-open");
      dialogOpener?.focus({ preventScroll: true });
    });
  }

  let inView = false;
  let pointer = null;
  let frame = 0;
  function updateScene() {
    frame = 0;
    if (reducedMotion.matches || !inView || document.hidden) {
      laptop.style.setProperty("--tilt-x", "0deg");
      laptop.style.setProperty("--tilt-y", "0deg");
      laptop.style.setProperty("--scene-y", "0px");
      return;
    }
    const rect = stage.getBoundingClientRect();
    const x = pointer ? Math.max(-.5, Math.min(.5, (pointer.x - rect.left) / rect.width - .5)) : 0;
    const y = pointer ? Math.max(-.5, Math.min(.5, (pointer.y - rect.top) / rect.height - .5)) : 0;
    laptop.style.setProperty("--tilt-x", `${(-y * 3).toFixed(2)}deg`);
    laptop.style.setProperty("--tilt-y", `${(x * 4).toFixed(2)}deg`);
    laptop.style.setProperty("--scene-y", `${Math.max(-8, Math.min(12, -rect.top * .026)).toFixed(2)}px`);
  }
  function requestSceneUpdate() {
    if (!frame) frame = requestAnimationFrame(updateScene);
  }
  stage.addEventListener("pointermove", event => {
    if (event.pointerType !== "mouse" || reducedMotion.matches) return;
    pointer = { x: event.clientX, y: event.clientY };
    requestSceneUpdate();
  }, { passive: true });
  stage.addEventListener("pointerleave", () => { pointer = null; requestSceneUpdate(); }, { passive: true });
  window.addEventListener("scroll", () => { if (inView && !reducedMotion.matches) requestSceneUpdate(); }, { passive: true });
  window.addEventListener("resize", requestSceneUpdate, { passive: true });
  document.addEventListener("visibilitychange", () => {
    document.documentElement.classList.toggle("page-inactive", document.hidden);
    pointer = null;
    requestSceneUpdate();
  });
  reducedMotion.addEventListener("change", requestSceneUpdate);
  if ("IntersectionObserver" in window) {
    new IntersectionObserver(entries => {
      inView = entries[0].isIntersecting;
      stage.classList.toggle("is-in-view", inView);
      requestSceneUpdate();
    }, { threshold: .05 }).observe(stage);
    const revealObserver = new IntersectionObserver(entries => {
      entries.forEach(entry => {
        if (entry.isIntersecting) {
          entry.target.classList.add("is-revealed");
          revealObserver.unobserve(entry.target);
        }
      });
    }, { threshold: .08 });
    document.querySelectorAll(".reveal").forEach(element => {
      if (!reducedMotion.matches && element.getBoundingClientRect().top > window.innerHeight) element.classList.add("will-reveal");
      revealObserver.observe(element);
    });
  } else {
    inView = true;
    stage.classList.add("is-in-view");
  }
})();
