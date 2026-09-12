# RHEL / CentOS / Rocky 9
#
# NOTE: the previous policy/centos9/rancher-selinux.spec declared
#   %define selinux_policyver 2.240.0-3
# which is a container-selinux version string, not a selinux-policy one
# (EL9 selinux-policy is 38.x). Preserved verbatim here to keep this
# change behaviour-preserving; see the PR description for the follow-up.
SELINUX_POLICYVER   := 2.240.0-3
CONTAINER_POLICYVER := 2.232.1-1
DISTTAG             := el9
SELINUX_UTILS       := libselinux-utils
BUILDREQUIRES       :=
M4PARAM             :=
