# Squad Decisions Archive

Older decisions (>30 days) archived from decisions.md for reference.

---

### 2026-04-10: Project initialized
**By:** Fortinbra (via Squad Coordinator)  
**What:** PerformanceNode — Raspberry Pi 5 setup scripts for a GitHub Actions self-hosted performance runner, targeting Raspberry Pi OS Lite (latest, 64-bit, headless/Bookworm). Scripts must be idempotent and unattended.  
**Universe:** Gundam Wing  
**Team:** Treize (Lead), Heero (Infrastructure), Wufei (Performance Engineer), Noin (Tester/QA)  
**Why:** Project kickoff.

---

### 2026-04-10: User directive — Container isolation required
**By:** Fortinbra (via Copilot)  
**What:** GitHub Actions jobs must NOT run directly on the Pi host OS. All jobs must execute inside disposable containers. The runner itself lives on the host, but each job is isolated in a container that is torn down after the job completes.  
**Why:** User requirement — captured for team memory. Affects infrastructure design (Docker required on host), runner configuration (container hooks or Docker executor), and performance test design (Wufei must account for container overhead in metrics).

---

### 2026-04-10: Approval gate before implementation
**By:** Fortinbra (via Copilot)  
**What:** No implementation work begins without explicit approval from Fortinbra. Specs, architecture decisions, and designs may be drafted, but no code or scripts are written until the user reviews and approves.  
**Why:** User directive — captured for team memory and process enforcement.

---
