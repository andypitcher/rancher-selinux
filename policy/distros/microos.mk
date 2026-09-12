# SUSE SLE Micro / MicroOS (openSUSE Tumbleweed build host)
#
# The SLE refpolicy predates the `watch' file permission and `map' on
# some run/log types, so rancher.te is compiled with -D rancher_suse to
# exclude those rules.
SELINUX_POLICYVER   := 20260219-1.1
CONTAINER_POLICYVER := 2.246.0-1.1
DISTTAG             := sle
SELINUX_UTILS       := selinux-tools
BUILDREQUIRES       := BuildRequires: container-selinux >= %{container_policyver}
M4PARAM             := -D rancher_suse
