<#import "template.ftl" as layout>

<@layout.registrationLayout displayInfo=true; section>
  <#if section = "header">
    <div id="kc-header-wrapper">
      <span class="kc-logo-text">DalaiLLAMA</span>
    </div>

  <#elseif section = "form">
    <#include "reset-password-form.ftl">

  <#elseif section = "info">
    <div class="instruction">
      ${msg("resetPassword")}
    </div>
  </#if>
</@layout.registrationLayout>
