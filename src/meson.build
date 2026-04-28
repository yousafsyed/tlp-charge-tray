gtk_dep = dependency('gtk+-3.0')
ayatana_dep = dependency('ayatana-appindicator3-0.1')
glib_dep = dependency('glib-2.0')
gio_dep = dependency('gio-2.0')

helper_install_dir = join_paths(get_option('prefix'), 'lib', 'charge-controller')

executable(
  'charge-controller',
  'charge-controller.vala',
  dependencies: [
    gtk_dep,
    ayatana_dep,
    glib_dep,
    gio_dep,
  ],
  install: true,
  install_dir: get_option('bindir'),
)

executable(
  'charge-controller-helper',
  'charge-controller-helper.vala',
  dependencies: [
    glib_dep,
    gio_dep,
  ],
  vala_args: [
    '--pkg=posix',
  ],
  install: true,
  install_dir: helper_install_dir,
)
