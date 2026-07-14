import type { AuthProvider } from "@refinedev/core";
import { supabaseClient } from "./supabaseClient";

// Only users whose `users.role = 'admin'` may enter this console. The role is
// re-checked on every `check()` — not just at login — so revoking someone's
// admin row logs them out on their next navigation.
async function isAdmin(userId: string): Promise<boolean> {
  const { data, error } = await supabaseClient
    .from("users")
    .select("role")
    .eq("id", userId)
    .single();
  if (error) return false;
  return data?.role === "admin";
}

export const authProvider: AuthProvider = {
  login: async ({ email, password }) => {
    const { data, error } = await supabaseClient.auth.signInWithPassword({
      email,
      password,
    });
    if (error) {
      return { success: false, error: { name: "Login failed", message: error.message } };
    }
    if (data?.user && (await isAdmin(data.user.id))) {
      return { success: true, redirectTo: "/" };
    }
    // Authenticated but not an admin — reject and sign back out.
    await supabaseClient.auth.signOut();
    return {
      success: false,
      error: { name: "Not authorized", message: "This account is not an admin." },
    };
  },

  logout: async () => {
    await supabaseClient.auth.signOut();
    return { success: true, redirectTo: "/login" };
  },

  onError: async (error) => {
    return { error };
  },

  check: async () => {
    const { data } = await supabaseClient.auth.getSession();
    const session = data?.session;
    if (!session) {
      return { authenticated: false, redirectTo: "/login" };
    }
    if (!(await isAdmin(session.user.id))) {
      await supabaseClient.auth.signOut();
      return { authenticated: false, redirectTo: "/login" };
    }
    return { authenticated: true };
  },

  getPermissions: async () => {
    const { data } = await supabaseClient.auth.getUser();
    if (!data?.user) return null;
    return (await isAdmin(data.user.id)) ? "admin" : null;
  },

  getIdentity: async () => {
    const { data } = await supabaseClient.auth.getUser();
    const user = data?.user;
    if (!user) return null;
    const { data: profile } = await supabaseClient
      .from("users")
      .select("name, email")
      .eq("id", user.id)
      .single();
    return {
      id: user.id,
      name: profile?.name ?? user.email ?? "Admin",
      email: profile?.email ?? user.email,
    };
  },
};
