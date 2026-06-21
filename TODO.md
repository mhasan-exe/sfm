# TODO

- [x] Inspect existing AdminLogsPage and AuditLogService.
- [ ] Rebuild audit logs UI to remove any infinite-scrolling behavior and ensure deterministic rendering.
- [ ] Use a totally different approach than StreamBuilder/ListView (per request).
- [ ] Add Firestore pagination with an explicit “Load more” action (no auto-scroll).
- [ ] Wire the UI to a new service method that fetches logs once per page.
- [ ] Verify compilation and run flutter analyze.

