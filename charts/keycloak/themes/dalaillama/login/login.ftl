<#import "template.ftl" as layout>

<@layout.registrationLayout displayInfo=true; section>
  <#if section = "header">
    <div id="kc-header-wrapper">
      <span class="kc-logo-text">Dalai Llama Platform</span>
    </div>

  <#elseif section = "form">
    <#include "login-form.ftl">

  <#elseif section = "info">
    <#include "login-info.ftl">
  </#if>
</@layout.registrationLayout>
