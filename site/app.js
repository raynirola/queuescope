const tabs = [...document.querySelectorAll('[role="tab"]')];
function selectTab(index, focus = false) {
  tabs.forEach((tab, i) => {
    tab.setAttribute('aria-selected', String(i === index));
    tab.tabIndex = i === index ? 0 : -1;
    document.getElementById(tab.getAttribute('aria-controls')).hidden = i !== index;
  });
  if (focus) tabs[index].focus();
}
tabs.forEach((tab, index) => {
  tab.addEventListener('click', () => selectTab(index));
  tab.addEventListener('keydown', (event) => {
    const keys = { ArrowDown: (index + 1) % tabs.length, ArrowRight: (index + 1) % tabs.length, ArrowUp: (index + tabs.length - 1) % tabs.length, ArrowLeft: (index + tabs.length - 1) % tabs.length, Home: 0, End: tabs.length - 1 };
    if (event.key in keys) { event.preventDefault(); selectTab(keys[event.key], true); }
  });
});
document.getElementById('copy-install')?.addEventListener('click', async () => {
  const status = document.getElementById('copy-status');
  try { await navigator.clipboard.writeText('brew install --cask raynirola/tap/queuescope'); status.textContent = 'Copied'; }
  catch { status.textContent = 'Select and copy the command above.'; }
});

const narrowLayout = matchMedia("(max-width: 800px)");
function updateTabOrientation() {
  document.querySelector('[role="tablist"]').setAttribute("aria-orientation", narrowLayout.matches ? "horizontal" : "vertical");
}
updateTabOrientation();
narrowLayout.addEventListener("change", updateTabOrientation);
