# Fedora 43
SELINUX_POLICYVER   := 43.10-1
CONTAINER_POLICYVER := 2.250.0-1
DISTTAG             := fc43
SELINUX_UTILS       := libselinux-utils
BUILDREQUIRES       := BuildRequires: container-selinux >= %{container_policyver}
M4PARAM             :=
