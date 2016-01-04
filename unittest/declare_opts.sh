#!/usr/bin/env bash

ETEST_declare_opts()
{
    set -- --file some_file --longer --long --whitespace "arg with whitespace" -shktlc blue -m -n arg1 arg2 arg3
    $(declare_opts                                                          \
        ":file f                     |   Which file should be processed."   \
        ":color c=yellow             |   Color to be used."                 \
        "long l longer s h k t m n   |   option with lots of variants"      \
        ":whitespace w               |   option expecting to receive something containing whitespace")
    etestmsg "$(dopt_dump)"

    assert_eq "blue" "${color}"
    assert_eq "some_file" "${file}"

    assert_eq "arg1" "$1"
    assert_eq "arg2" "$2"
    assert_eq "arg3" "$3"
}

ETEST_declare_opts_boolean()
{
    set -- -a -b -c d e f
    $(declare_opts "a" "b" "c" "d" "e" "f" )
    etestmsg "$(dopt_dump)"

    assert_eq 1 "${a}"
    assert_eq 1 "${b}"
    assert_eq 1 "${c}"

    assert_eq 0 "${d}"
    assert_eq 0 "${e}"
    assert_eq 0 "${f}"
}

ETEST_declare_opts_boolean_multi()
{
    set -- --another -va --verbose -vv -s --else
    $(declare_opts      \
        "verbose v"     \
        "another a"     \
        "something s"   \
        "else e") 
    etestmsg "$(dopt_dump)"

    assert_eq 1 "${verbose}"
    assert_eq 1 "${another}"
    assert_eq 1 "${something}"
    assert_eq 1 "${else}"
}

ETEST_declare_opts_short()
{
    set -- -nf a_file -c salmon -d=door
    $(declare_opts                  \
        ":file f   | the file"      \
        "numeric n | a number"      \
        ":color c  | the color"     \
        ":door d   | another argument")
    etestmsg "$(dopt_dump)"


    assert_eq "a_file" "${file}"
    assert_eq "salmon" "${color}"
    assert_eq "door"   "${door}"
}

ETEST_declare_opts_long()
{
    set -- --foo alpha --bar 10 --baz=30
    $(declare_opts \
        ":foo" \
        ":bar" \
        ":baz")
    etestmsg "$(dopt_dump)"

    assert_eq "alpha" "${foo}"
    assert_eq "10"    "${bar}"
    assert_eq "30"    "${baz}"
}

ETEST_declare_opts_required_arg()
{
    set -- -a
    try
    {
        $(declare_opts ":a") 
        etestmsg "$(dopt_dump)"

        die -r=243 "Should have failed parsing options."
    }
    catch
    {
        assert_ne 243 $?
    }
}

ETEST_declare_opts_shorts_crammed_together_with_arg()
{
    set -- -abc optarg arg
    $(declare_opts "a" "b" ":c") 
    etestmsg "$(dopt_dump)"

    assert_eq 1 "${a}"
    assert_eq 1 "${b}"
    assert_eq optarg "${c}"

    assert_eq "arg" "$1"
}

ETEST_declare_opts_shorts_crammed_together_required_arg()
{
    set -- -abc
    try
    {
        $(declare_opts "a" "b" ":c") 
        etestmsg "$(dopt_dump)"

        die -r=243 "Should have failed when parsing options but did not."
    }
    catch
    {
        assert_ne 243 $?
    }
}

ETEST_declare_opts_crazy_option_args()
{
    real_alpha="how about	whitespace?"
    real_beta="[]"
    real_gamma="*"
    real_kappa="\$1"

    set -- --alpha "${real_alpha}" --beta "${real_beta}" --gamma "${real_gamma}" --kappa "${real_kappa}"
    $(declare_opts ":alpha" ":beta" ":gamma" ":kappa")
    etestmsg "$(dopt_dump)"

    assert_eq "${real_alpha}" "${alpha}"
    assert_eq "${real_gamma}" "${gamma}"
    assert_eq "${real_beta}"  "${beta}"
    assert_eq "${real_kappa}" "${kappa}"
}

ETEST_declare_opts_arg_hyphen()
{
    set -- --foo - arg1
    $(declare_opts ":foo")
    etestmsg "$(dopt_dump)"

    [[ "${foo}" == "-" ]] || die "Foo argument was wrong"

    assert_eq "arg1" "$1"
}

ETEST_declare_opts_unexpected_short()
{
    set -- -a
    try
    {
        $(declare_opts "b")
        etestmsg "$(dopt_dump)"

        die -r=243 "Failed to blow up on unexpected option"
    }
    catch
    {
        assert_ne 243 $?
    }
}

ETEST_declare_opts_unexpected_long()
{
    set -- --foo
    try
    {
        $(declare_opts "bar")
        etestmsg "$(dopt_dump)"

        die -r=243 "Failed to blow up on unexpected option"
    }
    catch
    {
        assert_ne 243 $?
    }
}

ETEST_declare_opts_unexpected_equal_long()
{
    set -- --foo=1
    try
    {
        $(declare_opts "foo")
        etestmsg "$(dopt_dump)"

        die -r=243 "Failed to blow up on unexpected argument to option"
    }
    catch
    {
        assert_ne 243 $?
    }
}

ETEST_declare_opts_unexpected_equal_short()
{
    set -- -f=1
    try
    {
        $(declare_opts "foo f")
        etestmsg "$(dopt_dump)"

        die -r=243 "Failed to blow up on unexpected argument to option"
    }
    catch
    {
        assert_ne 243 $?
    }
}

ETEST_declare_opts_equal_empty()
{
    set -- -f=
    $(declare_opts ":foo f")
    etestmsg "$(dopt_dump)"
    assert_empty "${foo}"
}

ETEST_declare_opts_default()
{
    set --
    $(declare_opts                  \
        "alpha a=1"                 \
        ":beta b=3"                 \
        ":white w=with whitespace")
    etestmsg "$(dopt_dump)"

    assert_eq 1 "${alpha}"
    assert_eq 3 "${beta}"
    assert_eq "with whitespace" "${white}"
}

ETEST_declare_opts_boolean_defaults()
{
    set -- -a -b
    $(declare_opts "a=0" "b=1" "c=0" "d=1")
    etestmsg "$(dopt_dump)"

    assert_eq 1  "${a}"
    assert_eq 1  "${b}"
    assert_eq 0  "${c}"
    assert_eq 1  "${d}"
}

ETEST_declare_opts_recursive()
{
    foo()
    {
        $(declare_opts \
            ":as a"    \
            ":be b"    \
            ":c")
        etestmsg "${FUNCNAME}: $(dopt_dump)"

        bar --as 6 -b=5 -c 4

        assert_eq 3 "${as}"
        assert_eq 2 "${be}"
        assert_eq 1 "${c}"
    }

    bar()
    {
        $(declare_opts \
            ":as a"    \
            ":be b"    \
            ":c")
        etestmsg "${FUNCNAME}: $(dopt_dump)"

        assert_eq 6 "${as}"
        assert_eq 5 "${be}"
        assert_eq 4 "${c}"

    }

    foo  --as 3 -b=2 -c 1
}

ETEST_declare_opts_dump()
{
    set -- --alpha 10 --beta 20
    $(declare_opts ":alpha" ":beta")

    etestmsg "$(dopt_dump)"

    assert_eq 10 "${alpha}"
    assert_eq 20 "${beta}"

    local dump=$(dopt_dump)
    [[ "${dump}" =~ alpha ]]
    [[ "${dump}" =~ 10 ]]
    [[ "${dump}" =~ beta ]]
    [[ "${dump}" =~ 20 ]]

}

ETEST_declare_opts_no_options()
{
    etestmsg "Trying to run declare_opts in a function that received no arguments or options"
    set --
    $(declare_opts "a" ":b" "c=0")
    etestmsg "$(dopt_dump)"
    etestmsg "Succcess."
}

ETEST_declare_opts_no_hyphen_in_name()
{
    try
    {
        set --
        $(declare_opts "a-b")

        die -r=243 "Should have failed before this."
    }
    catch
    {
        assert_ne 243 $?
    }

}

# NOTE: Please ignore for the moment.  Declare_opts is still a work in progress
# and isn't integrated into anything for "real" use yet.
#ETEST_declare_opts_refuses_option_starting_with_no()
#{
#    try
#    {
#        $(declare_opts "no-option" "")
#
#        die -r=243 "Should have failed before reaching this point."
#    }
#    catch
#    {
#        assert_ne 243 $?
#    }
#}
