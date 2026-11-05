"use strict";

// Executes the shipped script and HTML in a small deterministic DOM/event model.
// These tests measure scheduling and accessibility behavior, not browser FPS,
// compositor cost, visual layout, or a replacement for rendered browser QA.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const dist = path.resolve(__dirname, "../dist");
const source = fs.readFileSync(path.join(dist, "app.js"), "utf8");
const html = fs.readFileSync(path.join(dist, "index.html"), "utf8");

class Events {
  constructor() { this.listeners = new Map(); }
  addEventListener(type, callback, options) {
    const entries = this.listeners.get(type) || [];
    entries.push({ callback, options }); this.listeners.set(type, entries);
  }
  removeEventListener(type, callback) {
    this.listeners.set(type, (this.listeners.get(type) || []).filter(entry => entry.callback !== callback));
  }
  emit(type, properties = {}) {
    const event = { type, target: this, defaultPrevented: false,
      preventDefault() { this.defaultPrevented = true; }, ...properties };
    for (const { callback } of [...(this.listeners.get(type) || [])]) callback(event);
    return event;
  }
}

class Classes {
  constructor() { this.values = new Set(); }
  add(...names) { names.forEach(name => this.values.add(name)); }
  remove(...names) { names.forEach(name => this.values.delete(name)); }
  contains(name) { return this.values.has(name); }
  toggle(name, force) {
    const enabled = force === undefined ? !this.contains(name) : force;
    if (enabled) this.add(name); else this.remove(name);
    return enabled;
  }
}

function matches(element, selector) {
  const tag = selector.match(/^[a-z][\w-]*/i)?.[0];
  if (tag && element.tagName !== tag.toLowerCase()) return false;
  for (const match of selector.matchAll(/\.([\w-]+)/g)) {
    if (!element.classList.contains(match[1])) return false;
  }
  const id = selector.match(/#([\w-]+)/)?.[1];
  if (id && !selector.includes("[") && element.id !== id) return false;
  for (const match of selector.matchAll(/\[([\w-]+)(?:(\^?=)["']([^"']*)["'])?\]/g)) {
    const value = element.getAttribute(match[1]);
    if (value === null) return false;
    if (match[2] === "=" && value !== match[3]) return false;
    if (match[2] === "^=" && !value.startsWith(match[3])) return false;
  }
  return true;
}

class Element extends Events {
  constructor(tagName, metrics) {
    super(); this.tagName = tagName.toLowerCase(); this.metrics = metrics;
    this.attributes = new Map(); this.dataset = {}; this.classList = new Classes();
    this.children = []; this.parentElement = null; this.hidden = false;
    this.textContent = ""; this.disabled = false;
    this.rect = { left: 0, top: 0, width: 900, height: 120 };
    this.properties = new Map();
    this.style = {
      setProperty: (key, value) => { metrics.styleWrites++; this.properties.set(key, value); },
      removeProperty: key => this.properties.delete(key),
      getPropertyValue: key => this.properties.get(key) || ""
    };
    if (this.tagName === "dialog") {
      this.showModal = () => { this.open = true; };
      this.close = () => { this.open = false; this.emit("close"); };
    }
  }
  get id() { return this.attributes.get("id") || ""; }
  get firstChild() { return this.children[0] || { textContent: "" }; }
  set className(value) { this.classList = new Classes(); this.classList.add(...value.split(/\s+/).filter(Boolean)); }
  setAttribute(name, value) {
    value = String(value); this.attributes.set(name, value);
    if (name === "class") this.className = value;
    if (name === "hidden") this.hidden = true;
    if (name === "disabled") this.disabled = true;
    if (name.startsWith("data-")) this.dataset[name.slice(5).replace(/-([a-z])/g, (_, char) => char.toUpperCase())] = value;
  }
  getAttribute(name) { return this.attributes.get(name) ?? null; }
  append(...children) { for (const child of children) { child.parentElement = this; this.children.push(child); } }
  replaceChildren(...children) { this.children.forEach(child => { child.parentElement = null; }); this.children = []; this.append(...children); }
  contains(target) { for (let node = target; node; node = node.parentElement) if (node === this) return true; return false; }
  closest(selector) { for (let node = this; node; node = node.parentElement) if (matches(node, selector)) return node; return null; }
  querySelectorAll(selector) {
    let contexts = [this];
    for (const part of selector.trim().split(/\s+/)) {
      const result = [];
      const visit = node => { for (const child of node.children) { if (matches(child, part)) result.push(child); visit(child); } };
      contexts.forEach(visit); contexts = result;
    }
    return [...new Set(contexts)];
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  getBoundingClientRect() {
    this.metrics.geometryReads++;
    return { ...this.rect, right: this.rect.left + this.rect.width, bottom: this.rect.top + this.rect.height };
  }
  focus() { this.focused = true; }
}

function parseMarkup(metrics) {
  const root = new Element("document", metrics);
  const stack = [root];
  const voids = new Set(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]);
  for (const token of html.matchAll(/<\/?([a-z][\w:-]*)([^<>]*?)>/gi)) {
    const tag = token[1].toLowerCase();
    if (token[0].startsWith("</")) {
      const index = stack.findLastIndex(node => node.tagName === tag);
      if (index > 0) stack.length = index;
      continue;
    }
    const element = new Element(tag, metrics);
    for (const attr of token[2].matchAll(/([^\s=\/]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g)) {
      element.setAttribute(attr[1], attr[2] ?? attr[3] ?? attr[4] ?? "");
    }
    stack.at(-1).append(element);
    if (!voids.has(tag) && !token[0].endsWith("/>")) stack.push(element);
  }
  return root;
}

function harness({ reduced = false, observerSupport = true, hash = "" } = {}) {
  const metrics = { geometryReads: 0, styleWrites: 0, requestedFrames: 0, executedFrames: 0, cancelledFrames: 0 };
  const root = parseMarkup(metrics);
  const document = new Events();
  document.documentElement = root.querySelector("html"); document.body = root.querySelector("body");
  document.querySelector = selector => root.querySelector(selector);
  document.querySelectorAll = selector => root.querySelectorAll(selector);
  document.getElementById = id => root.querySelectorAll("[id]").find(node => node.id === id) || null;
  document.createElement = tag => new Element(tag, metrics); document.hidden = false;
  const window = new Events();
  window.innerHeight = 800; window.innerWidth = 1200; window.location = { hash };
  const preference = new Events(); preference.matches = reduced;
  window.matchMedia = () => preference;
  const frames = new Map(); let nextID = 1;
  const requestAnimationFrame = callback => { metrics.requestedFrames++; const id = nextID++; frames.set(id, callback); return id; };
  const cancelAnimationFrame = id => { if (frames.delete(id)) metrics.cancelledFrames++; };
  const observers = [];
  class Observer {
    constructor(callback, options) { this.callback = callback; this.options = options; this.targets = new Set(); this.disconnected = false; observers.push(this); }
    observe(target) { this.targets.add(target); this.disconnected = false; }
    unobserve(target) { this.targets.delete(target); }
    disconnect() { this.targets.clear(); this.disconnected = true; }
  }
  const reveals = document.querySelectorAll("[data-reveal]");
  assert.ok(reveals.length > 0, "Fixture must include the shipped reveal elements");
  reveals.forEach((element, index) => { element.rect.top = index === 0 ? 200 : 1100 + index * 160; });
  const stage = document.getElementById("scene-stage");
  stage.rect = { left: 100, top: 200, width: 1000, height: 600 };
  const context = { document, window, console, requestAnimationFrame, cancelAnimationFrame,
    getComputedStyle: () => ({ display: "block" }) };
  if (observerSupport) { window.IntersectionObserver = Observer; context.IntersectionObserver = Observer; }
  vm.runInNewContext(source, context, { filename: "dist/app.js" });
  const result = {
    window, document, preference, stage, reveals, observers, frames, metrics,
    laptop: document.getElementById("laptop"),
    resetMetrics() { Object.keys(metrics).forEach(key => { metrics[key] = 0; }); },
    intersect(target, isIntersecting) {
      for (const observer of observers) if (observer.targets.has(target)) observer.callback([{ target, isIntersecting }]);
    },
    flush() {
      let turns = 0;
      while (frames.size) {
        assert.ok(turns++ < 10, "Animation frames must settle without a perpetual loop");
        const batch = [...frames]; frames.clear();
        for (const [, callback] of batch) { metrics.executedFrames++; callback(turns * 16); }
      }
    },
    visible(element) { return !element.classList.contains("will-reveal") || element.classList.contains("is-revealed"); }
  };
  return result;
}

test("bursts coalesce into one layout read, then stay idle without repeated writes", () => {
  const page = harness(); page.intersect(page.stage, true); page.flush(); page.resetMetrics();
  page.stage.rect.top = 120;
  for (let index = 0; index < 100; index++) page.window.emit("scroll");
  assert.equal(page.frames.size, 1);
  page.flush();
  assert.equal(page.metrics.executedFrames, 1);
  assert.equal(page.metrics.geometryReads, 1);
  assert.equal(page.frames.size, 0);
  const writes = page.metrics.styleWrites;
  page.window.emit("scroll"); page.flush();
  assert.equal(page.metrics.styleWrites, writes, "Unchanged geometry must not repeat inline style writes");
  page.flush(); assert.equal(page.frames.size, 0);
});

test("offscreen input does no animation work, and leaving view cancels a pending frame", () => {
  const page = harness(); page.intersect(page.stage, true); page.flush();
  page.window.emit("scroll"); assert.equal(page.frames.size, 1);
  page.intersect(page.stage, false); assert.equal(page.frames.size, 0);
  page.resetMetrics();
  for (let index = 0; index < 100; index++) {
    page.window.emit("scroll"); page.window.emit("resize");
    page.stage.emit("pointermove", { pointerType: "mouse", clientX: 300, clientY: 300 });
  }
  page.flush();
  assert.equal(page.metrics.requestedFrames, 0); assert.equal(page.metrics.geometryReads, 0);
});

test("the latest scene record wins when an observer delivery contains enter and exit", () => {
  const page = harness();
  const observer = page.observers.find(item => item.targets.has(page.stage));
  observer.callback([{ target: page.stage, isIntersecting: true }, { target: page.stage, isIntersecting: false }]);
  assert.equal(page.stage.classList.contains("is-in-view"), false);
  assert.equal(page.frames.size, 0, "A final offscreen record cannot leave scene work scheduled");
  observer.callback([{ target: page.stage, isIntersecting: false }, { target: page.stage, isIntersecting: true }]);
  assert.equal(page.stage.classList.contains("is-in-view"), true);
  assert.equal(page.frames.size, 1);
  page.flush(); assert.equal(page.frames.size, 0);
});

test("hidden pages and pagehide cancel work; returning resumes only after an event", () => {
  const page = harness(); page.intersect(page.stage, true); page.flush();
  page.window.emit("scroll");
  page.document.hidden = true; page.document.emit("visibilitychange");
  assert.equal(page.frames.size, 0); assert.ok(page.document.documentElement.classList.contains("page-inactive"));
  page.resetMetrics(); page.window.emit("scroll"); page.window.emit("resize"); page.flush();
  assert.equal(page.metrics.geometryReads, 0); assert.equal(page.metrics.requestedFrames, 0);
  page.document.hidden = false; page.document.emit("visibilitychange");
  assert.equal(page.frames.size, 1); page.window.emit("pagehide"); assert.equal(page.frames.size, 0);
  page.window.emit("pageshow"); page.flush(); assert.equal(page.frames.size, 0);
});

test("reduced motion reveals all prepared content and prevents subsequent animation work", () => {
  const page = harness(); page.intersect(page.stage, true); page.flush();
  assert.ok(page.reveals.some(element => !page.visible(element)));
  page.window.emit("scroll"); page.preference.matches = true; page.preference.emit("change");
  assert.equal(page.frames.size, 0); assert.ok(page.reveals.every(element => page.visible(element)));
  const revealObserver = page.observers.find(observer => observer.options.rootMargin);
  assert.ok(revealObserver.disconnected); assert.equal(revealObserver.targets.size, 0);
  page.resetMetrics(); page.window.emit("scroll"); page.window.emit("resize"); page.flush();
  assert.equal(page.metrics.requestedFrames, 0); assert.equal(page.metrics.geometryReads, 0);
  page.preference.matches = false; page.preference.emit("change"); page.flush();
  assert.ok(page.reveals.every(element => page.visible(element)), "Changing the preference back cannot hide revealed content");
});

test("an initial reduced-motion preference and missing IntersectionObserver both retain content", () => {
  const reduced = harness({ reduced: true });
  reduced.intersect(reduced.stage, true); reduced.window.emit("scroll"); reduced.flush();
  assert.ok(reduced.reveals.every(element => reduced.visible(element)));
  assert.equal(reduced.metrics.requestedFrames, 0);
  const fallback = harness({ observerSupport: false }); fallback.flush();
  assert.ok(fallback.reveals.every(element => fallback.visible(element)));
  assert.equal(fallback.frames.size, 0);
  fallback.stage.rect.top = -1000; fallback.resetMetrics();
  for (let index = 0; index < 100; index++) fallback.window.emit("scroll");
  fallback.flush();
  assert.equal(fallback.metrics.geometryReads, 1); assert.equal(fallback.frames.size, 0);
});

test("reveal observers release each visible target and never hide it again", () => {
  const page = harness();
  const target = page.reveals.find(element => !page.visible(element));
  const observer = page.observers.find(item => item.targets.has(target));
  assert.ok(observer);
  page.intersect(target, true);
  assert.ok(page.visible(target)); assert.equal(observer.targets.has(target), false);
  page.intersect(target, false); page.intersect(target, true);
  assert.ok(page.visible(target));
});

test("keyboard focus and hash navigation expose delayed content immediately", () => {
  const page = harness();
  const heading = page.document.getElementById("tasks-title");
  const parent = heading.closest("[data-reveal]");
  assert.equal(page.visible(parent), false);
  page.document.emit("focusin", { target: heading });
  assert.ok(page.visible(parent)); assert.ok(parent.classList.contains("reveal-immediately"));
  const section = page.document.getElementById("control");
  assert.ok(section.querySelectorAll("[data-reveal]").some(element => !page.visible(element)));
  page.window.location.hash = "#control"; page.window.emit("hashchange");
  assert.ok(section.querySelectorAll("[data-reveal]").every(element => page.visible(element)));
  page.window.location.hash = "#%broken";
  assert.doesNotThrow(() => page.window.emit("hashchange"));
});

test("initial deep links and uncancelled anchor clicks reveal their destinations", () => {
  const initial = harness({ hash: "#agent-title" });
  assert.ok(initial.visible(initial.document.getElementById("agent-title").closest("[data-reveal]")));
  const page = harness();
  const link = page.document.createElement("a"); link.setAttribute("href", "#questions");
  const destination = page.document.getElementById("questions").querySelectorAll("[data-reveal]");
  page.document.emit("click", { target: link, defaultPrevented: true });
  assert.ok(destination.some(element => !page.visible(element)));
  page.document.emit("click", { target: link });
  assert.ok(destination.every(element => page.visible(element)));
});
