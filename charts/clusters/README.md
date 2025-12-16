# Dalai Llama – Infra Platform

This repository defines the platform-level Kubernetes and Istio infrastructure
using Kustomize overlays.

## Structure
- base: shared resources across all environments
- components: reusable platform modules (Istio, security)
- overlays: environment-specific customization (dev, prod)

## Apply Dev
kubectl apply -k clusters/overlays/dev

## Apply Prod
kubectl apply -k clusters/overlays/prod
