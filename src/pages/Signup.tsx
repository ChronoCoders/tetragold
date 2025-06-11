import React from 'react';
import AuthLayout from '../components/AuthLayout';
import SignUpForm from '../components/auth/SignUpForm';

const Signup = () => {
  return (
    <AuthLayout 
      title="Create your account" 
      subtitle="Start your journey with Tetra Gold"
    >
      <SignUpForm />
    </AuthLayout>
  );
};

export default Signup;