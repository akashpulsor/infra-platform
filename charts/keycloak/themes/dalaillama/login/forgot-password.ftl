<#import "template.ftl" as layout>

<@layout.registrationLayout displayInfo=true; section>
  <#if section = "header">
    <div id="kc-header-wrapper">
      <span class="kc-logo-text">DalaiLLAMA</span>
    </div>

  <#elseif section = "form">
    <#include "forgot-password-form.ftl">

  <#elseif section = "info">
    <div class="instruction">
      ${msg("emailInstruction")}
    </div>
  </#if>
</@layout.registrationLayout>
