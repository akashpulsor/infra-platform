(function () {
  var countries = [
    { code: "+91", label: "🇮🇳 +91 India" },
    { code: "+1", label: "🇺🇸 +1 United States" },
    { code: "+44", label: "🇬🇧 +44 United Kingdom" },
    { code: "+971", label: "🇦🇪 +971 UAE" },
    { code: "+61", label: "🇦🇺 +61 Australia" },
    { code: "+65", label: "🇸🇬 +65 Singapore" },
    { code: "+49", label: "🇩🇪 +49 Germany" },
    { code: "+33", label: "🇫🇷 +33 France" },
    { code: "+81", label: "🇯🇵 +81 Japan" },
    { code: "+82", label: "🇰🇷 +82 South Korea" },
    { code: "+86", label: "🇨🇳 +86 China" },
    { code: "+880", label: "🇧🇩 +880 Bangladesh" },
    { code: "+977", label: "🇳🇵 +977 Nepal" },
    { code: "+94", label: "🇱🇰 +94 Sri Lanka" },
    { code: "+92", label: "🇵🇰 +92 Pakistan" }
  ];

  var phoneSelectors = [
    'input[name="phone_number"]',
    'input[name="user.attributes.phone_number"]',
    'input[id="phone_number"]',
    'input[id="user.attributes.phone_number"]',
    'input[name$=".phone_number"]',
    'input[id$=".phone_number"]',
    'input[name*="phone_number"]',
    'input[id*="phone_number"]'
  ];

  function digitsOnly(value) {
    return (value || "").replace(/\D/g, "");
  }

  function compactPhone(value) {
    var trimmed = (value || "").replace(/[^\d+]/g, "");
    if (trimmed.indexOf("00") === 0) {
      return "+" + trimmed.slice(2);
    }
    if (trimmed.charAt(0) !== "+" && trimmed.length > 10) {
      return "+" + trimmed;
    }
    return trimmed;
  }

  function detectCountry(value) {
    var compact = compactPhone(value);
    var sorted = countries.slice().sort(function (a, b) {
      return b.code.length - a.code.length;
    });

    for (var i = 0; i < sorted.length; i += 1) {
      if (compact.indexOf(sorted[i].code) === 0) {
        return sorted[i];
      }
    }

    return countries[0];
  }

  function nationalNumber(value, country) {
    var compact = compactPhone(value);
    if (compact.indexOf(country.code) === 0) {
      return digitsOnly(compact.slice(country.code.length));
    }
    return digitsOnly(compact.replace(/^\+/, ""));
  }

  function findPhoneInput() {
    for (var i = 0; i < phoneSelectors.length; i += 1) {
      var input = document.querySelector(phoneSelectors[i]);
      if (input && input.type !== "hidden") {
        return input;
      }
    }
    return null;
  }

  function enhancePhoneInput(input) {
    if (!input || input.dataset.dlPhoneEnhanced === "true") {
      return;
    }

    var selectedCountry = detectCountry(input.value);
    var wrapper = document.createElement("div");
    var select = document.createElement("select");

    wrapper.className = "dl-phone-input";
    select.className = "dl-country-code";
    select.setAttribute("aria-label", "Country code");

    countries.forEach(function (country) {
      var option = document.createElement("option");
      option.value = country.code;
      option.textContent = country.label;
      select.appendChild(option);
    });

    select.value = selectedCountry.code;
    input.dataset.dlPhoneEnhanced = "true";
    input.type = "tel";
    input.inputMode = "numeric";
    input.autocomplete = "tel-national";
    input.placeholder = "98765 43210";
    input.pattern = "[0-9\\s()\\-]{5,18}";
    input.title = "Enter mobile number without country code";
    input.classList.add("dl-phone-national");
    input.value = nationalNumber(input.value, selectedCountry);

    input.parentNode.insertBefore(wrapper, input);
    wrapper.appendChild(select);
    wrapper.appendChild(input);

    input.addEventListener("blur", function () {
      if (input.value.indexOf("+") !== 0 && input.value.indexOf("00") !== 0) {
        return;
      }
      var detected = detectCountry(input.value);
      select.value = detected.code;
      input.value = nationalNumber(input.value, detected);
    });

    var form = input.closest("form");
    if (form) {
      form.addEventListener("submit", function () {
        var localNumber = digitsOnly(input.value);
        input.value = localNumber ? select.value + localNumber : "";
      });
    }
  }

  function init() {
    enhancePhoneInput(findPhoneInput());
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }

  window.setTimeout(init, 300);
})();
