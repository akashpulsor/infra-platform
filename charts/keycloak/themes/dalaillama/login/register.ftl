<#import "template.ftl" as layout>

<@layout.registrationLayout displayInfo=true; section>
  <#if section = "header">
    <div id="kc-header-wrapper">
      <span class="kc-logo-text">DalaiLLAMA</span>
    </div>

  <#elseif section = "form">
    <#include "register-form.ftl">

  <#elseif section = "info">
    <#include "register-info.ftl">
  </#if>
</@layout.registrationLayout>
