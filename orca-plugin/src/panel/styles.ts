export const styles = `
:root, html.dark {
  --odd-n-bg: #3f3f46;
  --odd-n-fg: #e4e4e7;
  --odd-a-bg: #1e3a8a;
  --odd-a-fg: #bfdbfe;
  --odd-s-bg: #14532d;
  --odd-s-fg: #bbf7d0;
  --odd-w-bg: #713f12;
  --odd-w-fg: #fde68a;
  --odd-d-bg: #7f1d1d;
  --odd-d-fg: #fecaca;
  --odd-callout-border: #b45309;
  --odd-callout-bg: #2a1d0a;
  --odd-callout-title: #fbbf24;
  --odd-progress-fill: #22c55e;
  --odd-seg-active-bg: #1e3a8a;
  --odd-seg-active-fg: #ffffff;
  --odd-danger-text: #fca5a5;
}

html.light {
  --odd-n-bg: #e4e4e7;
  --odd-n-fg: #27272a;
  --odd-a-bg: #dbeafe;
  --odd-a-fg: #1e40af;
  --odd-s-bg: #dcfce7;
  --odd-s-fg: #166534;
  --odd-w-bg: #fef3c7;
  --odd-w-fg: #92400e;
  --odd-d-bg: #fee2e2;
  --odd-d-fg: #991b1b;
  --odd-callout-border: #d97706;
  --odd-callout-bg: #fffbeb;
  --odd-callout-title: #b45309;
  --odd-progress-fill: #16a34a;
  --odd-seg-active-bg: #1d4ed8;
  --odd-seg-active-fg: #ffffff;
  --odd-danger-text: #b91c1c;
}

* {
  box-sizing: border-box;
}

body {
  margin: 0;
  background: var(--orca-background, #18181b);
  color: var(--orca-foreground, #e4e4e7);
  font: 13px/1.45 var(--orca-font-sans, -apple-system, system-ui, sans-serif);
}

.pn {
  padding: 12px;
}

.hdr {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 8px;
  margin-bottom: 10px;
}

.hdr h1 {
  font-size: 15px;
  font-weight: 600;
  margin: 0;
}

.btn-refresh {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 26px;
  height: 26px;
  border: 1px solid var(--orca-border, #2e2e33);
  border-radius: 6px;
  background: var(--orca-card, #1f1f23);
  color: var(--orca-foreground, #e4e4e7);
  padding: 0;
  cursor: pointer;
}

.pn h4 {
  font-size: 11px;
  font-weight: 600;
  margin: 14px 0 6px;
  color: var(--orca-muted-foreground, #a1a1aa);
  text-transform: uppercase;
  letter-spacing: 0.04em;
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.cd {
  border: 1px solid var(--orca-border, #2e2e33);
  border-radius: var(--orca-radius, 8px);
  padding: 10px;
  margin-bottom: 8px;
  background: var(--orca-card, #1f1f23);
  color: var(--orca-card-foreground, var(--orca-foreground, #e4e4e7));
}

.bd {
  display: inline-block;
  border-radius: 999px;
  padding: 1px 8px;
  font-size: 11px;
  font-weight: 600;
  line-height: 1.5;
  flex-shrink: 0;
}

.badge-neutral {
  background: var(--odd-n-bg);
  color: var(--odd-n-fg);
}

.badge-accent {
  background: var(--odd-a-bg);
  color: var(--odd-a-fg);
}

.badge-success {
  background: var(--odd-s-bg);
  color: var(--odd-s-fg);
}

.badge-warning {
  background: var(--odd-w-bg);
  color: var(--odd-w-fg);
}

.badge-danger {
  background: var(--odd-d-bg);
  color: var(--odd-d-fg);
}

.callout {
  border: 1px solid var(--odd-callout-border);
  background: var(--odd-callout-bg);
  border-radius: var(--orca-radius, 8px);
  padding: 8px 10px;
  margin-bottom: 8px;
}

.callout-title {
  color: var(--odd-callout-title);
  font-weight: 600;
  margin-bottom: 2px;
}

.callout-item {
  font-size: 12px;
  margin-top: 2px;
}

.callout-link {
  display: block;
  width: 100%;
  text-align: left;
  background: transparent;
  border: none;
  color: inherit;
  font: inherit;
  font-size: 12px;
  padding: 0;
  cursor: pointer;
}

.callout-link:hover {
  text-decoration: underline;
}

.session-bar {
  margin-bottom: 8px;
}

.session-select {
  margin-top: 0;
}

.row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 6px;
  padding: 2px 0;
}

.session-title {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.row-inline {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-wrap: nowrap;
  flex-shrink: 0;
  white-space: nowrap;
}

.mu {
  color: var(--orca-muted-foreground, #a1a1aa);
  font-size: 12px;
}

.truncate {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.error-text {
  color: var(--odd-danger-text);
  font-size: 12px;
  margin: 4px 0;
}

.field-label {
  display: block;
  color: var(--orca-muted-foreground, #a1a1aa);
  font-size: 12px;
  margin-top: 8px;
}

.select {
  width: 100%;
  border: 1px solid var(--orca-border, #3f3f46);
  border-radius: 6px;
  padding: 5px 8px;
  background: var(--orca-background, #18181b);
  color: var(--orca-foreground, #e4e4e7);
  font: inherit;
  margin-top: 4px;
}

.roles-list {
  margin-top: 6px;
}

.role-line {
  color: var(--orca-muted-foreground, #a1a1aa);
  font-size: 12px;
}

.seg {
  display: flex;
  border: 1px solid var(--orca-border, #3f3f46);
  border-radius: 6px;
  overflow: hidden;
  margin-top: 4px;
}

.seg-btn {
  flex: 1;
  text-align: center;
  padding: 5px 8px;
  font: inherit;
  font-size: 12px;
  background: transparent;
  color: var(--orca-foreground, #e4e4e7);
  border: none;
  cursor: pointer;
}

.seg-btn.active {
  background: var(--odd-seg-active-bg);
  color: var(--odd-seg-active-fg);
  font-weight: 600;
}

.btn-reset {
  width: 100%;
  margin-top: 8px;
  padding: 5px 10px;
  border-radius: 6px;
  border: 1px solid var(--orca-border, #3f3f46);
  background: transparent;
  color: var(--orca-foreground, #e4e4e7);
  font: inherit;
  font-size: 12px;
  cursor: pointer;
}

button:disabled,
select:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.notes {
  margin-top: 6px;
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.pg {
  height: 6px;
  background: var(--orca-muted, #3f3f46);
  border-radius: 3px;
  overflow: hidden;
  margin: 6px 0;
}

.pg > i {
  display: block;
  height: 100%;
  background: var(--odd-progress-fill);
}

.it {
  padding: 5px 0;
  border-bottom: 1px solid var(--orca-border, #26262b);
}

.it:last-of-type {
  border-bottom: none;
}

.l1 {
  display: flex;
  align-items: center;
  gap: 6px;
  white-space: nowrap;
  overflow: hidden;
}

.l1 .t {
  overflow: hidden;
  text-overflow: ellipsis;
  min-width: 0;
}

.l2 {
  color: var(--orca-muted-foreground, #a1a1aa);
  font-size: 12px;
  padding-left: 2px;
  margin-top: 2px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.sum {
  background: var(--orca-muted, #26262b);
  border-radius: 6px;
  padding: 6px 8px;
  font-size: 12px;
  margin-top: 6px;
}

.fold {
  color: var(--orca-muted-foreground, #a1a1aa);
  font-size: 12px;
  padding: 4px 0;
  cursor: pointer;
  user-select: none;
}

.git-line {
  margin-top: 6px;
}

.worker-fallback {
  font-weight: 600;
  padding: 4px 0;
}

.empty-state {
  color: var(--orca-muted-foreground, #a1a1aa);
  padding: 12px 0;
  text-align: center;
}
`
