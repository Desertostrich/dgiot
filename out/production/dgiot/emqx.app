{application, emqx,
 [{id, "emqx"},
  {description, "EMQ X"},
  {vsn, "4.3.11"}, % strict semver, bump manually!
  {modules, []},
  {registered, []},
  {applications, [kernel,stdlib,gproc,gen_rpc,esockd,cowboy,sasl,os_mon]},
  {mod, {emqx_app,[]}},
  {env, []},
  {licenses, ["Apache-2.0"]},
  {maintainers, ["EMQ X Team <contact@emqx.io>"]},
  {links, [{"Homepage", "https://emqx.io/"},
           {"Github", "https://github.com/emqx/emqx"}
          ]}
]}.
