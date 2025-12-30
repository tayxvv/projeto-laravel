<?php

namespace App\Models;

use Illuminate\Foundation\Auth\User as Authenticatable;
use Illuminate\Notifications\Notifiable;
use Illuminate\Support\Str;
use PHPOpenSourceSaver\JWTAuth\Contracts\JWTSubject;

class User extends Authenticatable implements JWTSubject
{
    use Notifiable;

    protected $table = 'users';

    // UUID como chave primária
    protected $keyType = 'string';
    public $incrementing = false;

    // Laravel já usa created_at/updated_at por padrão, então ok
    public $timestamps = true;

    // Como sua coluna de senha não se chama "password"
    protected $hidden = [
        'password_hash',
        'remember_token',
    ];

    protected $fillable = [
        'tenant_id',
        'role',
        'name',
        'email',
        'password_hash',
        'is_active',
    ];

    protected $casts = [
        'id' => 'string',
        'tenant_id' => 'string',
        'role' => 'string',           // enum do Postgres (vai vir como string)
        'is_active' => 'boolean',
        'created_at' => 'datetime',
        'updated_at' => 'datetime',
    ];

    /**
     * Faz o Laravel Auth usar password_hash como campo de senha.
     */
    public function getAuthPassword()
    {
        return $this->password_hash;
    }

    /**
     * Se você quiser setar senha já hasheada automaticamente:
     * $user->password_hash = '123456'  -> salva hash.
     */
    public function setPasswordHashAttribute($value): void
    {
        if (!$value) return;

        // evita "double hash": se já parece hash bcrypt/argon, não re-hasheia
        if (Str::startsWith($value, ['$2y$', '$argon2i$', '$argon2id$'])) {
            $this->attributes['password_hash'] = $value;
            return;
        }

        $this->attributes['password_hash'] = bcrypt($value);
    }

    public function getJWTIdentifier()
    {
        return $this->getKey();
    }

    public function getJWTCustomClaims()
    {
        return [
            'role' => $this->role,
            'tenant_id' => $this->tenant_id,
        ];
    }
}
