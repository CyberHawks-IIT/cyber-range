<%@ Page Language="C#" %>
<%@ Import Namespace="System.Data.SqlClient" %>
<%@ Import Namespace="System.Security.Cryptography" %>
<%@ Import Namespace="System.Text" %>
<%@ Import Namespace="System.Configuration" %>
<script runat="server">
    protected void LoginButton_Click(object sender, EventArgs e)
    {
        string username = UsernameBox.Text;
        string password = PasswordBox.Text;
        string hash = ComputeSha1(password);

        string connStr = ConfigurationManager.ConnectionStrings["CyberHawksPortal"].ConnectionString;
        using (SqlConnection conn = new SqlConnection(connStr))
        {
            conn.Open();
            using (SqlCommand cmd = new SqlCommand("SELECT COUNT(*) FROM Users WHERE Username = @u AND PasswordHash = @h", conn))
            {
                cmd.Parameters.AddWithValue("@u", username);
                cmd.Parameters.AddWithValue("@h", hash);
                int count = (int)cmd.ExecuteScalar();
                if (count > 0)
                {
                    Session["Username"] = username;
                    Response.Redirect("Home.aspx");
                }
                else
                {
                    ErrorLabel.Text = "Invalid username or password.";
                }
            }
        }
    }

    protected string ComputeSha1(string input)
    {
        using (SHA1 sha1 = SHA1.Create())
        {
            byte[] bytes = sha1.ComputeHash(Encoding.UTF8.GetBytes(input));
            StringBuilder sb = new StringBuilder();
            foreach (byte b in bytes) sb.Append(b.ToString("X2"));
            return sb.ToString();
        }
    }
</script>
<!DOCTYPE html>
<html>
<head><title>CyberHawks Employee Portal - Login</title></head>
<body>
    <form id="form1" runat="server">
        <h1>CyberHawks Employee Portal</h1>
        <p>Username: <asp:TextBox ID="UsernameBox" runat="server" /></p>
        <p>Password: <asp:TextBox ID="PasswordBox" runat="server" TextMode="Password" /></p>
        <p><asp:Button ID="LoginButton" runat="server" Text="Log In" OnClick="LoginButton_Click" /></p>
        <p><asp:Label ID="ErrorLabel" runat="server" ForeColor="Red" /></p>
    </form>
</body>
</html>
