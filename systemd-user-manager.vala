// Copyright 2014 Steven Allen
// Distributed under the MIT/X11 license

using DBus;
using Gee;

namespace Logind {
    [DBus (name = "org.freedesktop.login1.Manager")]
    interface Manager : DBusProxy {
        public abstract signal void session_new(string id, ObjectPath path);
        public abstract signal void session_removed(string id, ObjectPath path);
        public abstract signal void prepare_for_sleep(bool active);
        public abstract signal void prepare_for_shutdown(bool active);
        public abstract UnixInputStream inhibit(string what, string who, string why, string mode) throws IOError;
    }
}

namespace Systemd {
    [DBus (name = "org.freedesktop.systemd1.Manager")]
    interface ManagerInterface : DBusProxy {
        public abstract void start_unit(string name, string mode = "replace", out ObjectPath job = null) throws IOError;
        public abstract void stop_unit(string name, string mode = "replace", out ObjectPath job = null) throws IOError;
        public abstract void subscribe() throws IOError;
        public abstract void unsubscribe() throws IOError;
        public abstract void exit() throws IOError;
        public abstract signal void job_removed(uint32 id, ObjectPath removed_job, string unit, string result);
    }

    class Manager : Object {
        private class Callback {
            public SourceFunc call;
            public Callback(SourceFunc f) {
                this.call = () => { return f(); };
            }
        }


        private HashMap<ObjectPath, Callback> waiting = new HashMap<ObjectPath, Callback>();
        private int subscribers = 0;
        private ManagerInterface dbus_interface;
        public Manager(BusType type = BusType.SESSION) throws IOError {

            dbus_interface = Bus.get_proxy_sync(type, "org.freedesktop.systemd1", "/org/freedesktop/systemd1");

            dbus_interface.job_removed.connect((id, removed_job, unit, result) => {
                Callback callback;
                if (waiting.unset(removed_job, out callback)) {
                    callback.call();
                }
            });
        }

        public async void start_unit_wait(string name, string mode = "replace") throws IOError {
            if (++subscribers == 1) {
                dbus_interface.subscribe();
            }
            
            ObjectPath job_path;
            start_unit(name, mode, out job_path);

            waiting[job_path] = new Callback(start_unit_wait.callback);
            yield;

            
            if (--subscribers == 0) {
                dbus_interface.unsubscribe();
            }
        }

        public void start_unit(string name, string mode = "replace", out ObjectPath job = null) throws IOError {
            dbus_interface.start_unit(name, mode, out job);
        }
        public void stop_unit(string name, string mode = "replace", out ObjectPath job = null) throws IOError {
            dbus_interface.stop_unit(name, mode, out job);
        }

        public void exit() throws IOError {
            dbus_interface.exit();
        }
    }
}

class Inhibitor : Object {
    private Logind.Manager manager;
    private UnixInputStream lock_file = null;

    public Inhibitor(Logind.Manager manager) {
        this.manager = manager;
    }

    public void release() {
        if (lock_file != null) {
            try {
                lock_file.close();
            } catch (IOError e) {
                stderr.printf("%s\n", e.message);
            } finally {
                lock_file = null;
            }
        }
    }

    public void aquire() throws IOError {
        lock_file = manager.inhibit("shutdown:sleep",
                "Systemd-Logind Listener",
                "Triggering user systemd targets.",
                "delay");
    }
}
        
        
void main(string[] args) {

    try {
        var loop = new MainLoop();

        Logind.Manager login_manager = Bus.get_proxy_sync(BusType.SYSTEM,
                "org.freedesktop.login1",
                "/org/freedesktop/login1");

        Systemd.Manager systemd_manager = new Systemd.Manager(BusType.SESSION);

        var inhibitor = new Inhibitor(login_manager);
        inhibitor.aquire();

        login_manager.session_new.connect((id, path) => {
            try {
              systemd_manager.start_unit(@"session@$id.target");
            } catch (IOError e) {
                stderr.printf("Failed to start session target: %s\n", e.message);
            }
        });

        login_manager.session_removed.connect((id, path) => {
            try {
                systemd_manager.start_unit(@"logout@$id.target");
            } catch (IOError e) {
                stderr.printf("Failed to start logout target: %s\n", e.message);
            }
        });


        login_manager.prepare_for_sleep.connect((active) => {
            if (active) {
                systemd_manager.start_unit_wait.begin("sleep.target", "replace", (obj,res) => {
                    try {
                        systemd_manager.start_unit_wait.end(res);
                    } catch (IOError e) {
                        stderr.printf("%s\n", e.message);
                    } finally {
                        inhibitor.release();
                    }
                });
            } else {
                try {
                    systemd_manager.stop_unit("sleep.target");
                } catch (IOError e) {
                    stderr.printf("%s\n", e.message);
                }
                try {
                    inhibitor.aquire();
                } catch (IOError e) {
                    stderr.printf("%s\n", e.message);
                }
            }
        });
        login_manager.prepare_for_shutdown.connect((active) => {
            if (active) {
                systemd_manager.start_unit_wait.begin("shutdown.target", "replace", (obj, res) => {
                    try {
                        systemd_manager.exit();
                    } catch (IOError e) {
                        stderr.printf("%s\n", e.message);
                    } finally {
                        inhibitor.release();
                    }
                });
            } // Else, wtf?
        });

        loop.run();
    } catch (IOError e) {
        stderr.printf(e.message);
    }
}
