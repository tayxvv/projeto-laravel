<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Validation\Rule;

class CreateUserRequest extends FormRequest
{
    /**
     * Determine if the user is authorized to make this request.
     */
    public function authorize(): bool
    {
        return true;
    }

    /**
     * Get the validation rules that apply to the request.
     *
     * @return array<string, \Illuminate\Contracts\Validation\ValidationRule|array<mixed>|string>
     */
    public function rules(): array
    {
        return [
            'tenant_id' => [
                'nullable',
                'uuid',
                'exists:organizations,id',
            ],

            'role' => [
                'nullable',
                'string',
                Rule::in(['ORG_ADMIN', 'MEMBER', 'SUPER_ADMIN']),
            ],

            'name' => [
                'required',
                'string',
                'max:150',
            ],

            'email' => [
                'required',
                'email',
                'max:180',
                Rule::unique('users', 'email'),
            ],

            'password' => [
                'required',
                'string',
                'min:6',
                'max:72',
            ],
        ];
    }

    /**
     * Get custom messages for validator errors.
     *
     * @return array<string, string>
     */
    public function messages(): array
    {
        return [
            'tenant_id.uuid' => 'O tenant_id deve ser um UUID válido.',
            'tenant_id.exists' => 'A organização especificada não existe.',
            'role.in' => 'O role deve ser um dos seguintes valores: ORG_ADMIN, MEMBER, SUPER_ADMIN.',
            'name.required' => 'O nome é obrigatório.',
            'name.max' => 'O nome não pode ter mais de 150 caracteres.',
            'email.required' => 'O email é obrigatório.',
            'email.email' => 'O email deve ser um endereço de email válido.',
            'email.unique' => 'Este email já está em uso.',
            'password.required' => 'A senha é obrigatória.',
            'password.min' => 'A senha deve ter pelo menos 6 caracteres.',
            'password.max' => 'A senha não pode ter mais de 72 caracteres.',
        ];
    }
}
