const measurementId = "G-MSGLSK2RV2";
const preferenceKey = "queuescope-analytics";

function startAnalytics() {
  if (window.gtag) return;
  window.dataLayer = window.dataLayer || [];
  window.gtag = function () {
    window.dataLayer.push(arguments);
  };
  window.gtag("js", new Date());
  window.gtag("config", measurementId, {
    allow_google_signals: false,
    allow_ad_personalization_signals: false,
  });

  const script = document.createElement("script");
  script.async = true;
  script.src = `https://www.googletagmanager.com/gtag/js?id=${measurementId}`;
  document.head.append(script);

  document.querySelectorAll("[data-download-location]").forEach((link) => {
    link.addEventListener("click", () => {
      window.gtag("event", "download_click", {
        download_location: link.dataset.downloadLocation,
        link_url: link.href,
        file_name: new URL(link.href).pathname.split("/").pop(),
        transport_type: "beacon",
      });
    });
  });
}

if (
  /^G-[A-Z0-9]+$/.test(measurementId) &&
  /^https?:$/.test(location.protocol)
) {
  let preference;
  try {
    preference = localStorage.getItem(preferenceKey);
  } catch {}
  if (preference === "accepted") startAnalytics();

  const notice = document.createElement("section");
  notice.className = "analytics-notice";
  notice.setAttribute("aria-label", "Website analytics");
  notice.innerHTML =
    '<p>Allow analytics cookies to help improve QueueScope? We measure visits and download clicks. <a href="privacy.html">Privacy</a></p><div><button type="button" data-consent="accepted">Allow analytics</button><button type="button" data-consent="declined">Decline</button></div>';
  notice.hidden = preference === "accepted" || preference === "declined";
  document.body.append(notice);

  notice.querySelectorAll("[data-consent]").forEach((button) => {
    button.addEventListener("click", () => {
      try {
        localStorage.setItem(preferenceKey, button.dataset.consent);
      } catch {}
      notice.hidden = true;
      if (button.dataset.consent === "accepted") startAnalytics();
      else if (window.gtag) {
        // Stop collection immediately, including the tag's automatic events.
        window[`ga-disable-${measurementId}`] = true;
        window.gtag = undefined;
        location.reload();
      }
    });
  });

  document
    .querySelector("[data-analytics-settings]")
    ?.addEventListener("click", () => {
      notice.hidden = false;
      notice.querySelector("button").focus();
    });
}
