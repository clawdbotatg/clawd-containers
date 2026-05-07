/* Polyfill window/localStorage/sessionStorage so libraries that touch them at
   import time don't crash during Next.js static export (server build). */
if (typeof globalThis.window === "undefined") {
  const memoryStore = () => {
    const store = new Map();
    return {
      getItem: key => (store.has(key) ? store.get(key) : null),
      setItem: (key, value) => {
        store.set(key, String(value));
      },
      removeItem: key => {
        store.delete(key);
      },
      clear: () => {
        store.clear();
      },
      key: i => Array.from(store.keys())[i] ?? null,
      get length() {
        return store.size;
      },
    };
  };

  // Make a fresh fake element each call. firstChild is itself a Text-like
  // node with mutable `.data` so libraries (e.g. goober via react-hot-toast)
  // that target `el.firstChild.data` during SSR don't crash.
  const makeFakeElement = () => {
    const textNode = { data: "", nodeType: 3 };
    const el = {
      style: {},
      setAttribute: () => {},
      getAttribute: () => null,
      removeAttribute: () => {},
      appendChild: () => {},
      removeChild: () => {},
      addEventListener: () => {},
      removeEventListener: () => {},
      classList: {
        add: () => {},
        remove: () => {},
        contains: () => false,
        toggle: () => false,
      },
      querySelector: () => null,
      querySelectorAll: () => [],
      insertBefore: () => {},
      cloneNode: () => makeFakeElement(),
      firstChild: textNode,
      childNodes: [textNode],
      parentNode: null,
      innerHTML: "",
      textContent: "",
      data: "",
    };
    return el;
  };
  const fakeElement = makeFakeElement();

  const fakeDocument = {
    addEventListener: () => {},
    removeEventListener: () => {},
    dispatchEvent: () => false,
    createElement: () => makeFakeElement(),
    createElementNS: () => makeFakeElement(),
    createTextNode: data => ({ data: String(data ?? ""), nodeType: 3 }),
    createDocumentFragment: () => makeFakeElement(),
    querySelector: () => null,
    querySelectorAll: () => [],
    getElementById: () => null,
    getElementsByTagName: () => [],
    getElementsByClassName: () => [],
    documentElement: { ...fakeElement },
    head: { ...fakeElement },
    body: { ...fakeElement },
    cookie: "",
    readyState: "complete",
    visibilityState: "visible",
  };

  const fakeWindow = {
    localStorage: memoryStore(),
    sessionStorage: memoryStore(),
    addEventListener: () => {},
    removeEventListener: () => {},
    dispatchEvent: () => false,
    location: { href: "", hostname: "", origin: "", pathname: "/", search: "", hash: "" },
    navigator: { userAgent: "node" },
    document: fakeDocument,
    matchMedia: () => ({
      matches: false,
      media: "",
      onchange: null,
      addListener: () => {},
      removeListener: () => {},
      addEventListener: () => {},
      removeEventListener: () => {},
      dispatchEvent: () => false,
    }),
  };

  globalThis.window = fakeWindow;
  globalThis.localStorage = fakeWindow.localStorage;
  globalThis.sessionStorage = fakeWindow.sessionStorage;
  globalThis.navigator = fakeWindow.navigator;
  globalThis.document = fakeDocument;
}
