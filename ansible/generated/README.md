# Generated vulnerable-range data

This directory holds data generated once by the `ad_base_accounts` role and
then treated as a stable source of truth on every re-run (re-running never
regenerates it, so account passwords stay consistent across playbook runs).

- `pool_accounts.csv` -- the 1000-account username/password/role pool
  (`username,password,role`). `role` is empty for ordinary pool accounts, or
  one of the named placeholders from CLAUDE.md's "Vulnerable AD range
  design" section (`writedacl_target`, `genericwrite_target`,
  `forcechangepw_target`, `writeowner_target`, `netlogon_creds`,
  `desc_field_pw`, `asreproast`, `smbshare_creds`, `weakcreds_1`..`weakcreds_10`).

This file is the lab's answer key as much as it is a credential store --
everything in this directory is gitignored (see `.gitignore`) and must never
be committed. If you need to hand this lab off or rebuild it elsewhere,
delete this directory first so `ad_base_accounts` regenerates a fresh,
independent pool rather than reusing these values.
