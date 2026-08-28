<%@ Page Language="C#" %>
<script runat="server">
    protected void Page_Load(object sender, EventArgs e)
    {
        if (Session["Username"] == null)
        {
            Response.Redirect("Default.aspx");
        }
        else
        {
            WelcomeLabel.Text = "Welcome, " + Session["Username"] + "!";
        }
    }
</script>
<!DOCTYPE html>
<html>
<head><title>CyberHawks Employee Portal</title></head>
<body>
    <form id="form1" runat="server">
        <h1>CyberHawks Employee Portal</h1>
        <p><asp:Label ID="WelcomeLabel" runat="server" /></p>
        <p>This is the internal employee portal for CyberHawks IT.</p>
    </form>
</body>
</html>
