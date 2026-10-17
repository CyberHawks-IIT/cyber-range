# Optional add-on: the full web portal

By default the range serves a lightweight ASP.NET Web Forms placeholder
"CyberHawks Employee Portal" on `web` (built into the core range's Phase G).
This add-on swaps in the **full** portal instead: the ASP.NET Core 8 MVC
application from the [web-app](https://github.com/CyberHawks-IIT/web-app) repo.

It's controlled by one toggle, `range_full_portal`, exactly like the
`range_monitoring` layer — off by default, and you can turn it on without
rebuilding anything else. It works with either setup (range-only or
range + monitoring).

**Same findings, more surface.** The full portal keeps every externally
observable finding the placeholder has — the `Web.config.bak` svc-web credential
leak, the portal database readable by all domain users, and the `admin` /
`abc123` app login — and adds a spread of app-layer web vulnerabilities
(broken access control / IDOR, reflected and stored XSS, blind SQL injection,
unrestricted file upload, and more). The full catalogue is in the web-app repo's
[SITE_PLAN.md](https://github.com/CyberHawks-IIT/web-app/blob/master/SITE_PLAN.md).

Every step ends with a **Check**.

## Extra prerequisites

The range builds the site from source **on the control node**, so that box needs:

- The **[.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)**
  (`dotnet --list-sdks` should list an `8.x` SDK).
- **git** (for the default clone of the web-app repo). Skip this if you build
  from a local checkout instead — see the notes at the end.

No new VMs and no extra manual downloads: the ASP.NET Core Hosting Bundle is
fetched onto `web` automatically.

## Steps

### A. Turn the toggle on and (re-)run the range playbook

The add-on is wired into `vulnerable-range.yml`: with `range_full_portal` on, it
skips the placeholder Phase G and deploys the full portal instead. Re-running is
idempotent.

```bash
cd cyber-range/ansible
ansible-playbook -i inventory/hosts.yml playbooks/vulnerable-range.yml -e range_full_portal=true
```

You can instead set `range_full_portal: true` in `inventory/group_vars/all.yml`
to make it the default. To deploy *only* the portal against an already-built
range, run the add-on playbook directly:

```bash
ansible-playbook -i inventory/hosts.yml playbooks/web-portal-full.yml -e range_full_portal=true
# or scope to just its tasks on a full run:
ansible-playbook -i inventory/hosts.yml playbooks/vulnerable-range.yml --tags web_portal_full -e range_full_portal=true
```

What it does, in order: builds the site on the control node (`dotnet publish`),
prepares `sql1` (drops any stale placeholder DB, creates the `svc-web` login,
grants it `dbcreator` so the app can create its own database), deploys the
published app to `web` under IIS via the Hosting Bundle, warms it up so EF
creates and seeds the database, then grants `CYBERHAWKS\Domain Users` read on
that database.

**Check:** the play recap shows no failures, and the "warm up the site" task
succeeded (that's the app creating and seeding its database on first start).

### B. Browse the portal

From anywhere that can reach the range, open the site on `web`:

```bash
curl -s http://10.0.2.5/ | grep -i "CyberHawks"
```

**Check:** you get the full MVC portal's home page (the CyberHawks Employee
Portal landing page), not the bare placeholder login form.

### C. Confirm the findings are intact

```bash
# The leaked backup config is retrievable over HTTP and carries svc-web's creds
curl -s http://10.0.2.5/Web.config.bak | grep -i "svc-web"

# The app login still works with the seeded admin / abc123
```

**Check:** `Web.config.bak` returns the connection string with the `svc-web`
password, that credential authenticates to `CyberHawksPortal` on `sql1`, any
domain user can read that database, and `admin` / `abc123` logs into the portal.

## Reverting to the placeholder

Turn the toggle back off and re-run; the placeholder Phase G redeploys and takes
over the Default Web Site again:

```bash
ansible-playbook -i inventory/hosts.yml playbooks/vulnerable-range.yml -e range_full_portal=false
```

(If you set it in `group_vars/all.yml`, change it back there.)

## Notes and overrides

All of these are role defaults in
[`roles/web_portal_full/defaults/main.yml`](../../ansible/roles/web_portal_full/defaults/main.yml);
override any with `-e`.

- **`svc-web` password** (`web_portal_full_svc_web_password`): defaults to the
  exact value the site's own leaked `Web.config.bak` advertises, so the leak
  resolves to a working credential out of the box.
- **Hosting Bundle version** (`dotnet_hosting_bundle_version` /
  `dotnet_hosting_bundle_url`): pin a different ASP.NET Core 8 patch, or point
  at a locally mirrored installer.
- **Build from a local checkout** instead of cloning
  (`web_portal_full_src=/path/to/web-app`): useful when iterating on the site,
  or when the control node has no internet access to GitHub.
