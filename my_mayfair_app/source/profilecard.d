module profilecard;

import mayfair;

/*
    Someone's name and what they do, with a button to follow them: a widget whose insides are
    laid out in a view of its own, resources/views/profilecard.xml. The card is that view's <root>, and its
    controller too, so the view's ids fill its fields and its buttons call its methods.

        <ProfileCard name="Ada Lovelace" role="Programmer"/>

    Its name and role are observable properties: as well as setName() and the rest, which a view
    sets them with, each has a property other code can listen to or bind to, nameProperty and
    roleProperty.
*/
@View("profilecard.xml")
class ProfileCard : Column
{
public:
    mixin Properties;

    this()
    {
        View.load(this);
    }

protected:
    // Only as wide as what's in it, as a button is, so the layout it's in decides where it sits
    override float computeMaxWidth() const nothrow @nogc { return usePrefSize; }

private:
    @observable string _name;   /// Whose card it is.
    @observable string _role;   /// What they do.

    @xml Label nameLabel, roleLabel;
    @xml Button followButton;
    bool following;

    void nameChanged() { nameLabel.setText(_name); }
    void roleChanged() { roleLabel.setText(_role); }

    void follow()
    {
        following = !following;
        followButton.setText(following ? "Following" : "Follow");
    }
}
