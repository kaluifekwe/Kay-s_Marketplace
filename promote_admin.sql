UPDATE users SET role = 'admin' WHERE email = 'kaluifekwe6@gmail.com' RETURNING id, email, role;
