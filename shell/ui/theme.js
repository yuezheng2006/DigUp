// Configurable appearance + accent themes (Chinese fork). Stored in localStorage so the
 // shell stays low-invasion: no Rust settings schema change required.
"use strict";
const DigUpTheme = (() => {
  const appearanceKey = "digup.appearanceMode";
  const colorKey = "digup.colorTheme";
  const appearances = ["system", "light", "dark"];
  const colors = ["system", "moss", "amber", "slate"];

  function read(key, allowed, fallback) {
    const value = localStorage.getItem(key);
    return allowed.includes(value) ? value : fallback;
  }

  function apply() {
    const appearance = read(appearanceKey, appearances, "system");
    const color = read(colorKey, colors, "system");
    const root = document.documentElement;
    if (appearance === "system") root.removeAttribute("data-appearance");
    else root.setAttribute("data-appearance", appearance);
    if (color === "system") root.removeAttribute("data-color");
    else root.setAttribute("data-color", color);
    return { appearance, color };
  }

  function setAppearance(value) {
    if (!appearances.includes(value)) return apply();
    localStorage.setItem(appearanceKey, value);
    return apply();
  }

  function setColor(value) {
    if (!colors.includes(value)) return apply();
    localStorage.setItem(colorKey, value);
    return apply();
  }

  return { apply, setAppearance, setColor, read: () => ({
    appearance: read(appearanceKey, appearances, "system"),
    color: read(colorKey, colors, "system"),
  }) };
})();
DigUpTheme.apply();
