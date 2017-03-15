// Copyright 2014 Steven Allen
// Distributed under the MIT/X11 license

using DBus;
using Gee;

const string LOGIND_BUS_NAME = "org.freedesktop.login1";
const string SYSTEMD_BUS_NAME = "org.freedesktop.systemd1";

namespace Logind {
    [DBus (name = "org.freedesktop.login1.Manager")]
    interface Manager : DBusProxy {
        public abstract signal void session_new(string id, ObjectPath path);
        public abstract signal void session_removed(string id, ObjectPath path);
        public abstract signal void prepare_for_sleep(bool active);
        public abstract signal void prepare_for_shutdown(bool active);
        public abstract UnixInputStream inhibit(string what, string who, string why, string mode) throws IOError;
    }

	struct SessionTuple {
		public string id;
		public ObjectPath path;
	}

    [DBus (name = "org.freedesktop.login1.User")]
	interface User : DBusProxy {
		public abstract SessionTuple[] sessions {
			owned get;
		}
		public abstract SessionTuple display {
			owned get;
		}
	}

    [DBus (name = "org.freedesktop.login1.Session")]
	interface Session : DBusProxy {
		public abstract string display {
			owned get;
		}
	}
}

namespace Systemd {
    [DBus (name = "org.freedesktop.systemd1.Manager")]
    interface ManagerInterface : DBusProxy {
        public abstract void start_unit(string name, string mode = "replace", out ObjectPath job = null) throws IOError;
        public abstract void stop_unit(string name, string mode = "replace", out ObjectPath job = null) throws IOError;
        public abstract void set_environment(string[] environment) throws IOError;
        public abstract void unset_environment(string[] environment) throws IOError;
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

            dbus_interface = Bus.get_proxy_sync(type, SYSTEMD_BUS_NAME, "/org/freedesktop/systemd1");

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

        public void set_graphical(ObjectPath session) throws IOError {
            Logind.Session graphical_session = Bus.get_proxy_sync(
                BusType.SYSTEM,
                LOGIND_BUS_NAME,
                session);

            string display = graphical_session.display;
            if (display != "") {
                dbus_interface.set_environment({@"DISPLAY=$display"});
            } // otherwise, we expect it to have been set elsewhere.
        }
        public void unset_graphical() throws IOError {
            dbus_interface.unset_environment({"DISPLAY"});
        }

        public void exit() throws IOError {
            dbus_interface.exit();
        }
        public void start_session(string id) throws IOError {
            start_unit(@"session@$id.target");
        }

        public void stop_session(string id) throws IOError {
            stop_unit(@"session@$id.target");
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

        Logind.Manager login_manager = Bus.get_proxy_sync(BusType.SYSTEM, LOGIND_BUS_NAME, "/org/freedesktop/login1");

        Logind.User user = Bus.get_proxy_sync(
            BusType.SYSTEM,
            LOGIND_BUS_NAME,
            "/org/freedesktop/login1/user/self");

        Systemd.Manager systemd_manager = new Systemd.Manager(BusType.SESSION);

        var inhibitor = new Inhibitor(login_manager);
        inhibitor.aquire();

        login_manager.session_new.connect((id, path) => {
            try {
                string graphical_session_id = user.display.id;
                if (graphical_session_id == id) {
                    systemd_manager.set_graphical(path);
                }
            } catch (IOError e) {
                stderr.printf("Failed to set DISPLAY: %s\n", e.message);
            }

            try {
                systemd_manager.start_session(id);
            } catch (IOError e) {
                stderr.printf("Failed to start session target: %s\n", e.message);
            }
        });

        login_manager.session_removed.connect((id, path) => {
            try {
                // Slightly racy...
                string graphical_session_id = user.display.id;
                if (graphical_session_id == id) {
                    systemd_manager.unset_graphical();
                }
                systemd_manager.stop_session(id);
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
        {
            Logind.SessionTuple graphical_session_tuple = user.display;
            if (graphical_session_tuple.id != "") {
                systemd_manager.set_graphical(graphical_session_tuple.path);
            }
            foreach (Logind.SessionTuple session in user.sessions) {
                try {
                    systemd_manager.start_session(session.id);
                } catch (IOError e) {
                    stderr.printf("Failed to start session target: %s\n", e.message);
                }
            }
        }

        loop.run();
    } catch (IOError e) {
        stderr.printf(e.message);
    }
}
