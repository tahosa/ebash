#!/usr/bin/env bash

ETEST_netns_create_list_delete()
{
    NS_NAME=namespace_${FUNCNAME}
    trap_add "netns_delete ${NS_NAME}"

    # Create the namespace and verify it exists
    netns_create ${NS_NAME}
    assert netns_exists ${NS_NAME}

    # Verify the loopback is up in the namespace
    netns_exec ${NS_NAME} ip link | grep "lo:" | assert grep -q "UP"

    # Verify the namespace shows up in the list of namespaces
    echo $(netns_list) | assert grep -q ${NS_NAME}

    # Delete and verify it is gone
    netns_delete ${NS_NAME}
    assert_false netns_exists ${NS_NAME}
}

ETEST_netns_with_whitespace_create_list_delete()
{
    NS_NAME="name space ${FUNCNAME}"
    trap_add "netns_delete \"${NS_NAME}\""

    # Create the namespace and verify it exists
    netns_create "${NS_NAME}"
    assert netns_exists "\"${NS_NAME}\""

    # Verify the loopback is up in the namespace
    netns_exec "${NS_NAME}" ip link | grep "lo:" | assert grep -q "UP"

    # Verify the namespace shows up in the list of namespaces
    echo $(netns_list) | assert grep -q "\"${NS_NAME}\""

    # Delete and verify it is gone
    netns_delete "${NS_NAME}"
    assert_false netns_exists "\"${NS_NAME}\""
}

ETEST_netns_exec()
{
    NS_NAME=namespace_${FUNCNAME}
    trap_add "netns_delete ${NS_NAME}"

    # Create the namespace and verify it exists
    netns_create ${NS_NAME}
    assert netns_exists ${NS_NAME}

    # Look for network interfaces in the namespace; lo should be the only one
    ifaces=$(netns_exec ${NS_NAME} ls /sys/class/net)
    assert_eq "${ifaces}" "lo"
}

ETEST_netns_list()
{
    # Create some namespaces
    NS_NAMES=()
    for i in $(seq 1 5); do
        name=namespace_${FUNCNAME}${i}
        netns_create ${name}
        NS_NAMES+=(${name})
        trap_add "netns_delete ${name}"
    done

    # Verify each namespace shows up in the list
    for name in ${NS_NAMES[@]}; do
        echo $(netns_list) | assert grep -q ${name}
    done
}

ETEST_netns_pack()
{
    #make empty pack
    netns_init pack1

    #check that the empty pack doesn't contain ns_name (it will contain the key, but no value)
    assert_false pack_contains pack1 ns_name

    #check that the empty pack is not valid
    assert_false netns_check_pack pack1

    #add values
    pack_set pack1 ns_name=foo devname=dev peer_devname=pdev connected_nic=blah bridge_cidr=1.2.3.4/12 nic_cidr=2.3.4.5/15

    #check that the populated pack is ok
    assert_true netns_check_pack pack1

    #change the ns_name to be 20 characters
    pack_set pack1 ns_name=abcdefghijklmnopqrst

    #check that the pack is not valid
    assert_false netns_check_pack pack1

    #change the ns_name back and give bridge_cidr just an ip address
    pack_set pack1 ns_name=foo bridge_cidr=1.2.3.4

    #check that the pack is not valid
    assert_false netns_check_pack pack1

    #change the bridge_cidr back and give nic_cidr just an ip address
    pack_set pack1 bridge_cidr=1.2.3.4/12 nic_cidr=2.3.4.5

    #check that the pack is not valid
    assert_false netns_check_pack pack1

    #change the nic_cidr back
    pack_set pack1 nic_cidr=2.3.4.5/15

    #check that the pack is valid
    assert_true netns_check_pack pack1
}
