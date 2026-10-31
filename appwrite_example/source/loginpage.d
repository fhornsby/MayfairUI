module loginpage;

import std.string : strip;
import std.typecons : Nullable;
import appwrite;
import mayfair;
import backend;
import todopage;

/*
    The first page, laid out in resources/views/login.xml: an email address and password to sign in with, or
    to make an account with. Once signed in, the window shows a TodoPage in its place, as
    my_mayfair_app's pages do, with scene.setRoot.

    Someone still signed in from the last run (the session's kept in a file: see Backend) doesn't
    see the form at all; initialise() checks for them and goes straight on.
*/
@View("login.xml")
class LoginPage : Column
{
public:
    this()
    {
        View.load(this);
    }

    void initialise()
    {
        wait("Checking whether you're signed in…");
        async(() => backend.currentUser())
            .then((Nullable!(models.User) user) {
                if (user.isNull)
                    stopWaiting("");
                else
                    open(user.get);
            })
            .onError((Exception e) { stopWaiting(e.msg); });
    }

private:
    @xml Column form;
    @xml TextField email;
    @xml PasswordField password;
    @xml Label status;
    @autowired Backend backend;

    void signIn() { submit(false); }
    void signUp() { submit(true); }

    void submit(bool newAccount)
    {
        const address = email.text.strip, secret = password.text;
        if (!address.length || !secret.length)
            return stopWaiting("Enter your email address and a password.");
        wait(newAccount ? "Making your account…" : "Signing in…");
        async(() => newAccount ? backend.signUp(address, secret) : backend.signIn(address, secret))
            .then((models.User user) { open(user); })
            .onError((Exception e) { stopWaiting(e.msg); });
    }

    void open(models.User user)
    {
        scene.setRoot(new TodoPage(user));
    }

    // The form's switched off while the server's asked, so it can't be sent twice
    void wait(string message)
    {
        status.setText(message);
        form.setDisable(true);
    }

    void stopWaiting(string message)
    {
        status.setText(message);
        form.setDisable(false);
    }
}
